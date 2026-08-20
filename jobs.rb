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

  # Everything the list pages read, except `output`.
  #
  # `output` is deliberately absent. rq-review caps a review at 200 KB and this
  # query takes 50 rows, so SELECT * hauls up to 10 MB out of Postgres -- on
  # every load of a page that then prints a state word and a timestamp. The
  # size is still wanted (the panel summary shows it), and octet_length costs
  # no bandwidth.
  LIST_COLUMNS = "id, login, dev_box_id, repo, pr_number, box_name, state, phase, " \
                 "torn_down_at, error, created_at, started_at, finished_at, " \
                 "octet_length(output) AS output_bytes"

  def for_user(login) = DB.rows(<<~SQL, [login])
    SELECT #{LIST_COLUMNS} FROM review_jobs WHERE login = $1 ORDER BY created_at DESC LIMIT 50
  SQL

  # The review text for one job, fetched only when something is going to show
  # it. Scoped by login like every other read here.
  def output(login, id)
    DB.row("SELECT output FROM review_jobs WHERE login = $1 AND id = $2", [login, id])&.fetch("output")
  end

  # The review text for several jobs at once, as {id => output}. The sessions
  # page inlines only the handful it shows expanded, so this stays one round
  # trip instead of one per card.
  def outputs(login, ids)
    return {} if ids.empty?
    holders = ids.each_index.map { |i| "$#{i + 2}" }.join(", ")
    DB.rows("SELECT id, output FROM review_jobs WHERE login = $1 AND id IN (#{holders})", [login, *ids])
      .each_with_object({}) { |r, h| h[r["id"]] = r["output"] }
  end

  # An older wrapper wrote bay's build log and claude's review into one stream.
  # Split on the marker it used, so an old job still reads well instead of
  # burying the review under thousands of build lines. Returns [noise, review];
  # noise is nil for anything written by the current wrapper.
  REVIEW_MARKER = "== review".freeze

  def split_output(text)
    full = text.to_s
    idx = full.rindex(REVIEW_MARKER)
    return [nil, full] unless idx
    [full[0...idx], full[(idx + REVIEW_MARKER.length)..].to_s.lstrip]
  end

  # Which jobs the sessions page prints inline. Everything else loads when its
  # panel is opened.
  #
  # A review is capped at 200 KB and this page lists 50 jobs, so inlining all
  # of them built a 10 MB page -- almost all of it reviews from weeks ago,
  # inside panels nobody opened. Spending a byte budget newest-first means the
  # review you just ran is always already there, and the page has a ceiling
  # instead of growing with your history.
  INLINE_BUDGET = Integer(ENV.fetch("RQ_INLINE_BYTES", "262144"))

  def inline_ids(jobs)
    spent = 0
    jobs.each_with_object([]) do |j, ids|
      size = j["output_bytes"].to_i
      next unless size.positive?
      # A live job is inline whatever it costs: the no-JS refresh has nothing
      # else to show it with, and there are only ever a few.
      if %w[queued running].include?(j["state"])
        ids << j["id"]
      elsif spent + size <= INLINE_BUDGET
        spent += size
        ids << j["id"]
      end
    end
  end

  # Newest job per pull request, so a row can show its state. A job whose box
  # has been torn down is skipped: its review is still readable on the sessions
  # page, but the row should offer Review again rather than claim it is done.
  #
  # The queue page reads only the state word off this, so the query returns
  # three columns rather than fifty whole reviews. The inner LIMIT keeps the
  # old window: the 50 newest jobs, then newest-per-pull-request within them.
  def by_key(login)
    DB.rows(<<~SQL, [login]).each_with_object({}) { |j, h| h["#{j["repo"]}##{j["pr_number"]}"] = j }
      SELECT DISTINCT ON (repo, pr_number) repo, pr_number, state
      FROM (
        SELECT repo, pr_number, state, torn_down_at, created_at
        FROM review_jobs WHERE login = $1 ORDER BY created_at DESC LIMIT 50
      ) recent
      WHERE torn_down_at IS NULL
      ORDER BY repo, pr_number, created_at DESC
    SQL
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
