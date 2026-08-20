require_relative "db"
require_relative "devbox"

# The review job queue. A job moves queued -> running -> done|failed.
#
# The work happens on the user's dev box and takes minutes, so the worker does
# not hold it open: rq-review detaches, and the worker polls. That means a
# worker restart loses nothing -- a running job is picked up again by its box
# name on the next tick.
module Jobs
  # A job that has been running longer than this is treated as lost. The dev
  # box may have rebooted, or the wrapper may have been killed.
  STALE_AFTER = Integer(ENV.fetch("RQ_JOB_TIMEOUT", "3600"))

  module_function

  def enqueue(login:, repo:, pr_number:)
    box = DB.row("SELECT * FROM dev_boxes WHERE login = $1", [login])
    return {ok: false, error: "no dev box registered"} unless box

    name = DevBox.box_name(repo, pr_number)
    DevBox.validate!(repo: repo, pr_number: pr_number, box: name)

    row = DB.row(<<~SQL, [login, box["id"], repo, pr_number, name])
      INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name)
      VALUES ($1, $2, $3, $4, $5) RETURNING *
    SQL
    {ok: true, job: row}
  rescue PG::UniqueViolation
    # The partial unique index already refuses a second live job for this pull
    # request, so a double click is harmless.
    {ok: false, error: "a review is already running for this pull request"}
  rescue DevBox::Error => e
    {ok: false, error: e.message}
  end

  def for_user(login) = DB.rows(<<~SQL, [login])
    SELECT * FROM review_jobs WHERE login = $1 ORDER BY created_at DESC LIMIT 50
  SQL

  # Newest job per pull request, so a row can show its state. A job whose box
  # has been torn down is skipped: its review is still readable on the sessions
  # page, but the row should offer Review again rather than claim it is done.
  def by_key(login)
    for_user(login).each_with_object({}) do |j, h|
      next if j["torn_down_at"]
      key = "#{j["repo"]}##{j["pr_number"]}"
      h[key] ||= j
    end
  end

  # Marks every job that used this box, so the rows go back to offering Review.
  def mark_torn_down(login, box_name)
    DB.exec(<<~SQL, [login, box_name])
      UPDATE review_jobs
      SET torn_down_at = now(),
          -- A queued or running job still occupies review_jobs_live_idx, so
          -- without settling it the user is told "can be reviewed again" and
          -- then refused with "a review is already running". The box is gone;
          -- the job cannot continue.
          state       = CASE WHEN state IN ('queued', 'running') THEN 'failed' ELSE state END,
          error       = CASE WHEN state IN ('queued', 'running')
                             THEN 'the box was torn down' ELSE error END,
          finished_at = COALESCE(finished_at, now())
      WHERE login = $1 AND box_name = $2 AND torn_down_at IS NULL
    SQL
  end

  def cancel(login:, id:)
    DB.exec(<<~SQL, [login, id])
      UPDATE review_jobs SET state = 'failed', error = 'cancelled', finished_at = now()
      WHERE login = $1 AND id = $2 AND state IN ('queued', 'running')
    SQL
  end

  # --- worker side ----------------------------------------------------------

  # Takes one queued job. SKIP LOCKED lets several workers run without ever
  # handing the same job to two of them.
  def claim
    DB.row(<<~SQL)
      UPDATE review_jobs SET state = 'running', started_at = now()
      WHERE id = (
        SELECT id FROM review_jobs WHERE state = 'queued'
        ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED
      )
      RETURNING *
    SQL
  end

  def running = DB.rows("SELECT * FROM review_jobs WHERE state = 'running' ORDER BY started_at")

  def dev_box(job) = DB.row("SELECT * FROM dev_boxes WHERE id = $1", [job["dev_box_id"]])

  # Progress for a job that is still running. Only touches output, so it can
  # never move a job out of running by accident.
  #
  # The last clause matters: the worker polls every few seconds and re-sends
  # the whole log each time, but claude writes in bursts, so most ticks carry
  # exactly what is already stored. Without it every tick rewrote a row with a
  # 200 KB toasted column -- a new row version, a new toast chain and the WAL
  # for both -- to store nothing new.
  def progress(id, output, phase = nil)
    DB.exec(<<~SQL, [output, phase, id])
      UPDATE review_jobs SET output = $1, phase = COALESCE($2, phase)
      WHERE id = $3 AND state = 'running'
        AND (output IS DISTINCT FROM $1 OR phase IS DISTINCT FROM COALESCE($2, phase))
    SQL
  end

  def finish(id, state, output: nil, error: nil)
    DB.exec(<<~SQL, [state, output, error, id])
      UPDATE review_jobs SET state = $1, output = $2, error = $3, finished_at = now() WHERE id = $4
    SQL
  end

  # A follow-up puts a finished job back to work in the same box, so the page
  # streams the answer the way it streamed the review.
  def reopen(id, login)
    DB.row(<<~SQL, [login, id])
      UPDATE review_jobs
      -- started_at drives the staleness timeout, so a follow-up on a job from
      -- last week would be given up on at the first blip, discarding the answer.
      SET state = 'running', phase = 'reviewing', finished_at = NULL, error = NULL,
          started_at = now()
      WHERE login = $1 AND id = $2 AND state IN ('done', 'failed')
      RETURNING *
    SQL
  end

  def stale?(job, now: Time.now)
    started = job["started_at"]
    return false unless started
    started = Time.parse(started.to_s) unless started.is_a?(Time)
    now - started > STALE_AFTER
  end
end
