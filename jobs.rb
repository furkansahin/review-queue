require_relative "db"
require_relative "baybox"

# The review job queue. A job moves queued -> running -> done|failed.
#
# The work happens on the user's baybox and takes minutes, so the worker does
# not hold it open: the run detaches, and the worker polls. That means a
# worker restart loses nothing -- a running job is picked up again by its box
# name on the next tick.
module Jobs
  # A job that has been running longer than this is treated as lost. The
  # baybox may have rebooted, or the run may have been killed.
  STALE_AFTER = Integer(ENV.fetch("RQ_JOB_TIMEOUT", "3600"))

  module_function

  KINDS = %w[review work].freeze

  # kind "work" is an issue being worked on, and pr_number is then the issue's
  # number. See the schema for why they share a table.
  def enqueue(login:, repo:, pr_number:, kind: "review")
    return {ok: false, error: "unknown job kind #{kind.inspect}"} unless KINDS.include?(kind)
    box = DB.row("SELECT * FROM bayboxes WHERE login = $1", [login])
    return {ok: false, error: "no baybox registered"} unless box

    name = kind == "work" ? BayBox.issue_box_name(repo, pr_number) : BayBox.box_name(repo, pr_number)
    BayBox.validate!(repo: repo, pr_number: pr_number, box: name)

    row = DB.row(<<~SQL, [login, box["id"], repo, pr_number, name, kind])
      INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, kind)
      VALUES ($1, $2, $3, $4, $5, $6) RETURNING *
    SQL
    {ok: true, job: row}
  rescue PG::UniqueViolation
    # The partial unique index already refuses a second live job for this pull
    # request, so a double click is harmless.
    {ok: false, error: kind == "work" ? "work on this issue is already running"
                                      : "a review is already running for this pull request"}
  rescue BayBox::Error => e
    {ok: false, error: e.message}
  end

  # Everything the list pages read, except `output`.
  #
  # `output` is deliberately absent. A review is capped at 200 KB and this
  # query takes 50 rows, so SELECT * hauls up to 10 MB out of Postgres -- on
  # every load of a page that then prints a state word and a timestamp. The
  # size is still wanted (the panel summary shows it), and octet_length costs
  # no bandwidth.
  LIST_COLUMNS = "id, login, baybox_id, repo, pr_number, box_name, state, phase, " \
                 "torn_down_at, error, created_at, started_at, finished_at, " \
                 "kind, branch, summary, pr_url, " \
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

  # Older runs wrote bay's build log and claude's review into one stream.
  # Split on the marker they used, so an old job still reads well instead of
  # burying the review under thousands of build lines. Returns [noise, review];
  # noise is nil when there is no marker to split on.
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
  #
  # Per kind, so a review of a pull request never answers for work on an issue
  # and the other way round.
  def by_key(login, kind = "review")
    DB.rows(<<~SQL, [login, kind]).each_with_object({}) { |j, h| h["#{j["repo"]}##{j["pr_number"]}"] = j }
      SELECT DISTINCT ON (repo, pr_number) repo, pr_number, state, pr_url
      FROM (
        SELECT repo, pr_number, state, pr_url, torn_down_at, created_at
        FROM review_jobs WHERE login = $1 AND kind = $2 ORDER BY created_at DESC LIMIT 50
      ) recent
      WHERE torn_down_at IS NULL
      ORDER BY repo, pr_number, created_at DESC
    SQL
  end

  def set_branch(id, branch) = DB.exec("UPDATE review_jobs SET branch = $1 WHERE id = $2", [branch, id])
  def set_summary(id, summary) = DB.exec("UPDATE review_jobs SET summary = $1 WHERE id = $2", [summary, id])

  def set_pr(login, id, url)
    DB.exec("UPDATE review_jobs SET pr_url = $1 WHERE login = $2 AND id = $3", [url, login, id])
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

  # What the worker polls. Not a follow-up that is still starting: see reopen.
  # Past the grace it is polled anyway, so a web process that died between
  # reopening a row and starting its run cannot leave the row running forever.
  STARTING_GRACE = "2 minutes"

  def running = DB.rows(<<~SQL)
    SELECT * FROM review_jobs
    WHERE state = 'running'
      AND (phase IS DISTINCT FROM 'starting' OR started_at < now() - interval '#{STARTING_GRACE}')
    ORDER BY started_at
  SQL

  def baybox(job) = DB.row("SELECT * FROM bayboxes WHERE id = $1", [job["baybox_id"]])

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
  #
  # 'starting', not 'reviewing', until the run is actually going -- started()
  # says when. The row is reopened before the question is copied to the box,
  # which is two ssh round trips, and the state file this host keeps for the
  # box still says the last run's "done" until the new run is detached. A
  # worker tick landing in that gap read "done", finished the job with the
  # previous answer, and stopped watching it: the page showed no live output,
  # and the new answer sat on the box until the next question reopened the
  # row. It happened in production -- a follow-up marked done 0.1s after it
  # was asked.
  def reopen(id, login)
    DB.row(<<~SQL, [login, id])
      UPDATE review_jobs
      -- started_at drives the staleness timeout, so a follow-up on a job from
      -- last week would be given up on at the first blip, discarding the answer.
      SET state = 'running', phase = 'starting', finished_at = NULL, error = NULL,
          started_at = now()
      WHERE login = $1 AND id = $2 AND state IN ('done', 'failed')
      RETURNING *
    SQL
  end

  # The follow-up's run is going on the box: the worker may watch it now.
  def started(id)
    DB.exec(<<~SQL, [id])
      UPDATE review_jobs SET phase = 'reviewing'
      WHERE id = $1 AND state = 'running' AND phase = 'starting'
    SQL
  end

  def stale?(job, now: Time.now)
    started = job["started_at"]
    return false unless started
    started = Time.parse(started.to_s) unless started.is_a?(Time)
    now - started > STALE_AFTER
  end
end
