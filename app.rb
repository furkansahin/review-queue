require "roda"
require "json"
require "securerandom"
require_relative "queue_service"
require_relative "auth"
require_relative "snooze"

# The review feature needs Postgres and a dev box. Without DATABASE_URL the
# dashboard still runs and simply does not offer it, so this branch can deploy
# before the database exists.
REVIEWS_ENABLED = !ENV["DATABASE_URL"].to_s.empty?
if REVIEWS_ENABLED
  require_relative "db"
  require_relative "jobs"
  require_relative "devbox"
require_relative "runner"
require_relative "stream_render"
require_relative "transcript"
require_relative "markdown"

# bay runs here now. RQ_TRANSPORT=ssh falls back to the wrapper on the box,
# which is what every box ran before this change.
BOX = (ENV.fetch("RQ_TRANSPORT", "bay") == "bay") ? Runner : DevBox
  warn "[review-queue] #{DB.describe}"
  DB.setup!
end

def env_required(key)
  ENV[key] || abort("missing required env var #{key}")
end

# The shared colour tokens, inlined into the <style> of every page that is not
# the queue. Read once at boot: it used to be a File.read inside the template,
# so every render of every page went to the filesystem for a constant.
PALETTE = File.read(File.expand_path("views/_palette.erb", __dir__)).freeze

# Global defaults: every signed-in user watches the same scope and label.
REGISTRY = ServiceRegistry.new(
  idle_ttl: ENV.fetch("RQ_IDLE_TTL", "3600").to_i,
  max_users: ENV.fetch("RQ_MAX_USERS", "25").to_i,
  scope: ENV.fetch("RQ_SCOPE", "repo:ubicloud/ubicloud"),
  warn_days: ENV.fetch("RQ_WARN_DAYS", "2").to_i,
  hot_days: ENV.fetch("RQ_HOT_DAYS", "4").to_i,
  stale_days: ENV.fetch("RQ_STALE_DAYS", "7").to_i,
  ttl: ENV.fetch("RQ_CACHE_TTL", "300").to_i,
  # How many pull requests are fetched at once. Each one then fans out again
  # for its own timeline, so the real number of requests in flight is a few
  # times this. Raise it to make a rebuild faster, at the cost of asking
  # GitHub harder -- past a point that earns a secondary rate limit.
  concurrency: ENV.fetch("RQ_CONCURRENCY", "5").to_i,
  quick_lines: ENV.fetch("RQ_QUICK_LINES", "50").to_i,
  lines_per_min: ENV.fetch("RQ_LINES_PER_MIN", "20").to_i,
  # How many of your merged pull requests the Merged tab lists. Each one costs
  # a single extra call, for its size. The list itself is one search.
  merged_limit: ENV.fetch("RQ_MERGED_LIMIT", "10").to_i
)

SNOOZE_SECONDS = ENV.fetch("RQ_SNOOZE_DAYS", "7").to_i * 86_400

# Live log limits. Puma serves on RQ_PUMA_THREADS threads and a stream occupies
# one for its whole life, so this must leave enough to serve pages. A stream
# ends itself after RQ_STREAM_SECONDS; the browser's EventSource reconnects on
# its own, which also frees the slot for anyone who was refused.
MAX_STREAMS = ENV.fetch("RQ_MAX_STREAMS", "6").to_i
STREAM_SECONDS = ENV.fetch("RQ_STREAM_SECONDS", "110").to_i
STREAMS = {n: 0, lock: Mutex.new}

def stream_slot
  STREAMS[:lock].synchronize do
    return false if STREAMS[:n] >= MAX_STREAMS
    STREAMS[:n] += 1
  end
  true
end

def release_stream_slot
  STREAMS[:lock].synchronize { STREAMS[:n] -= 1 if STREAMS[:n].positive? }
end

# How recently signed in a user has to be for the page to stop trying to fix a
# 401 by signing them in again. Long enough to cover the redirect back from
# GitHub, short enough that a genuinely expired token still refreshes itself.
REAUTH_GRACE = ENV.fetch("RQ_REAUTH_GRACE", "30").to_i

# Only a hint in the settings box. It is deliberately NOT applied as a default:
# a shared default is what made every user inherit one person's topic feed.
SUGGESTED_LABEL = ENV.fetch("RQ_LABEL", "")

# Where a user fetches the wrapper from. Points at this repo so the script the
# dashboard talks to is the script in version control.
WRAPPER_URL = ENV.fetch("RQ_WRAPPER_URL",
  "https://raw.githubusercontent.com/furkansahin/review-queue/main/devbox/rq-review")

# Fails closed: with no allowlist nobody gets in, rather than everybody.
# Required at boot alongside the other secrets. It was not, so a fresh deploy
# booted green and then 500'd on every page that touches a stored key.
env_required("RQ_ENCRYPTION_KEY") if REVIEWS_ENABLED

ALLOWED_LOGINS = env_required("RQ_ALLOWED_LOGINS")
  .split(",").map { |s| s.strip.downcase }.reject(&:empty?).freeze
abort("RQ_ALLOWED_LOGINS is empty") if ALLOWED_LOGINS.empty?

OAUTH = GitHubOAuth.new(
  client_id: env_required("RQ_GITHUB_CLIENT_ID"),
  client_secret: env_required("RQ_GITHUB_CLIENT_SECRET"),
  redirect_uri: env_required("RQ_BASE_URL").chomp("/") + "/auth/callback"
)

class ReviewQueue < Roda
  plugin :render, engine: "erb", views: File.expand_path("views", __dir__), escape: true
  plugin :sessions, secret: env_required("RQ_SESSION_SECRET"), key: "_review_queue",
    cookie_options: {same_site: :lax, http_only: true, secure: ENV["RQ_INSECURE_COOKIES"] != "1"}
  # Default is :raise, which would surface a stack trace on a stale form.
  plugin :route_csrf, csrf_failure: :empty_403
  # For the live log. A streaming response holds its Puma thread for as long as
  # it runs, so /sessions/stream bounds both how many may run at once and how
  # long each one lives.
  plugin :streaming
  # Defence in depth: an unhandled exception should not reach a user as a bare
  # 500 with nothing to act on, and should leave something in the log.
  plugin :error_handler do |e|
    warn "[review-queue] #{e.class}: #{e.message}"
    warn e.backtrace.take(8).join("\n") if e.backtrace
    response.status = 500
    if request.path.start_with?("/sessions/tail")
      response["Content-Type"] = "application/json"
      '{"error":"server error"}'
    else
      response["Content-Type"] = "text/html; charset=utf-8"
      "<p style=\"font:14px system-ui;padding:24px\">Something went wrong: " \
        "#{Rack::Utils.escape_html(e.class.to_s)}. It is in the server log. " \
        "<a href=\"/sessions\">Back to sessions</a></p>"
    end
  end
  plugin :default_headers,
    "Content-Type" => "text/html; charset=utf-8",
    "X-Frame-Options" => "DENY",
    "X-Content-Type-Options" => "nosniff",
    "Referrer-Policy" => "no-referrer"

  # An id from a form goes into a bigint column. Anything that is not a positive
  # integer must never reach the database: "" and "abc" both raise
  # PG::InvalidTextRepresentation, which surfaced as a bare 500.
  def param_id(value)
    v = value.to_s.strip
    v.match?(/\A[0-9]{1,18}\z/) && v.to_i.positive? ? v.to_i : nil
  end

  def current_login = session["login"]

  def current_token = session["token"]

  def allowed?(login) = ALLOWED_LOGINS.include?(login.to_s.downcase)

  route do |r|
    r.get "healthz" do
      response["Content-Type"] = "text/plain"
      "ok"
    end

    r.on "auth" do
      # One-shot nonce tying the callback to the browser that started the flow.
      r.get "start" do
        state = SecureRandom.urlsafe_base64(24)
        session["oauth_state"] = state
        r.redirect OAUTH.authorize_url(state)
      end

      r.get "callback" do
        expected = session.delete("oauth_state")
        code = r.params["code"].to_s
        if expected.nil? || expected.empty? || !r.params["state"].to_s.eql?(expected)
          next view("login", locals: {error: "Sign-in expired or was tampered with. Try again."},
            layout: false)
        end
        next r.redirect "/login" if code.empty?

        begin
          token = OAUTH.exchange(code)
          login = GitHubClient.new(token).get("/user").fetch("login")
        rescue StandardError => e
          next view("login", locals: {error: "GitHub sign-in failed: #{e.message}"}, layout: false)
        end

        unless allowed?(login)
          next view("login", locals: {error: "@#{login} is not on this dashboard's allowlist."},
            layout: false)
        end

        # Clear first. Without this, switching GitHub accounts -- or a second
        # person on a shared browser -- inherits the previous user's watch
        # label and snooze list, which is the same inheritance bug the watch
        # label was moved per-user to fix. It also rotates the session across
        # an authentication boundary.
        #
        # Signing in again as the SAME person is not that boundary, though.
        # The watch label and the snooze list live only in the session, so
        # clearing them on a token refresh would quietly throw away everything
        # the user had put out of sight. Carry them over, and only them.
        same_user = current_login == login
        carried = same_user ? session.to_hash.slice("label", "snoozed") : {}
        REGISTRY.forget(login)
        session.clear
        carried.each { |k, v| session[k] = v }
        session["login"] = login
        session["token"] = token
        # When this stamp is recent, the page will not send the user back here:
        # a token minted seconds ago that is already refused is not something
        # another round trip fixes.
        session["authed_at"] = Time.now.to_i
        r.redirect "/"
      end
    end

    r.get "login" do
      next r.redirect "/" if current_login
      view("login", locals: {error: nil}, layout: false)
    end

    r.post "logout" do
      check_csrf!
      REGISTRY.forget(current_login) if current_login
      session.clear
      r.redirect "/login"
    end

    next r.redirect "/login" unless current_login && current_token

    service = REGISTRY.for(current_login, current_token, label: session["label"].to_s)

    r.post "refresh" do
      check_csrf!
      service.snapshot(force: true)
      r.redirect "/?#{r.query_string}"
    end

    r.on "devbox" do
      next r.redirect "/" unless REVIEWS_ENABLED

      current = -> { DB.row("SELECT * FROM dev_boxes WHERE login = $1", [current_login]) }

      # A blank box means keep what is stored, "-" means clear it. The page
      # never shows a token back, so blank cannot mean "set it to empty".
      token_update = lambda do |typed, row, column|
        v = typed.to_s.strip
        next row && row[column] if v.empty?
        next nil if v == "-"
        Crypto.encrypt(v)
      end

      r.post "save" do
        check_csrf!
        error = nil
        begin
          t = DevBox.check_target!(host: r.params["host"], ssh_user: r.params["ssh_user"],
                                   port: r.params["port"].to_s.empty? ? 22 : r.params["port"])
          skills = DevBox.check_skills_repo!(r.params["skills_repo"])
          repo_path = DevBox.check_repo_path!(r.params["repo_path"])
          # A blank field means "leave what is stored". Otherwise a user who
          # only wants to change the host would have to retype both tokens,
          # and the page never shows them back.
          stored = current.call
          claude = token_update.call(r.params["claude_token"], stored, "claude_token_enc")
          github = token_update.call(r.params["github_token"], stored, "github_token_enc")
          if (row = current.call)
            # Keep the existing keypair: changing the address must not force the
            # user to reinstall the key.
            DB.exec(<<~SQL, [t[:host], t[:ssh_user], t[:port], skills, repo_path, claude, github, row["id"]])
              UPDATE dev_boxes SET host=$1, ssh_user=$2, port=$3, skills_repo=$4,
                                   repo_path=$5, claude_token_enc=$6, github_token_enc=$7
              WHERE id=$8
            SQL
          else
            priv, pub = DevBox.generate_keypair(comment: "review-queue:#{current_login}")
            # The array is built first: a heredoc body starts on the next line,
            # so a continuation inside the argument list lands inside the SQL.
            values = [current_login, t[:host], t[:ssh_user], t[:port],
                      Crypto.encrypt(priv), pub, skills, repo_path, claude, github]
            DB.exec(<<~SQL, values)
              INSERT INTO dev_boxes (login, host, ssh_user, port, private_key_enc, public_key,
                                     skills_repo, repo_path, claude_token_enc, github_token_enc)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            SQL
          end
          # The box is where this has to take effect, so tell it now. A box that
          # cannot be reached keeps the stored value: Test connection pushes it
          # again, and so does the next save.
          if (row = current.call)
            res = BOX.run(row, "skills #{skills}")
            session["devbox_notice"] = res[:ok] ? nil : "saved, but the box did not take the skills repository yet: #{(res[:error] || res[:output]).to_s[0, 200]}"
          end
        rescue DevBox::Error => e
          error = e.message
        end
        session["devbox_error"] = error
        r.redirect "/devbox"
      end

      # Everything a box needs except the key that grants access to do it.
      r.post "prepare" do
        check_csrf!
        if (row = current.call)
          res = BOX.respond_to?(:prepare_box) ? BOX.prepare_box(row) : {ok: false, error: "not supported"}
          detail = (res[:output].to_s.empty? ? res[:error].to_s : res[:output]).strip
          # The last part of it, which is where the failure is -- but str[-n..]
          # is nil when the string is shorter than n, and that silently threw
          # away every short answer, including every success.
          tail = detail.length > 1200 ? detail[(detail.length - 1200)..] : detail
          session[res[:ok] ? "devbox_notice" : "devbox_error"] =
            (res[:ok] ? "Prepared the box.\n" : "Could not finish preparing the box.\n") + tail.to_s
          DB.exec("UPDATE dev_boxes SET last_ok_at = now(), last_error = NULL WHERE id = $1", [row["id"]]) if res[:ok]
        end
        r.redirect "/devbox"
      end

      r.post "test" do
        check_csrf!
        if (row = current.call)
          res = BOX.check(row)
          if res[:ok]
            DB.exec("UPDATE dev_boxes SET last_ok_at = now(), last_error = NULL WHERE id = $1", [row["id"]])
            # A reachable box is the moment to make the stored value true again,
            # for a box that was down when it was saved, or was rebuilt since.
            BOX.run(row, "skills #{row["skills_repo"]}")
          else
            detail = (res[:error] || res[:output].to_s)[0, 500]
            DB.exec("UPDATE dev_boxes SET last_error = $1 WHERE id = $2", [detail, row["id"]])
          end
        end
        r.redirect "/devbox"
      end

      # A new keypair revokes the old one, which is the point.
      r.post "rotate" do
        check_csrf!
        if (row = current.call)
          priv, pub = DevBox.generate_keypair(comment: "review-queue:#{current_login}")
          DB.exec("UPDATE dev_boxes SET private_key_enc=$1, public_key=$2, last_ok_at=NULL, last_error=NULL WHERE id=$3",
                  [Crypto.encrypt(priv), pub, row["id"]])
        end
        r.redirect "/devbox"
      end

      r.post "delete" do
        check_csrf!
        DB.exec("DELETE FROM dev_boxes WHERE login = $1", [current_login])
        r.redirect "/devbox"
      end

      r.get true do
        box = current.call
        view("devbox", locals: {box: box, login: current_login,
                                error: session.delete("devbox_error"),
                                notice: session.delete("devbox_notice"),
                                wrapper_url: WRAPPER_URL,
                                bay_transport: BOX == Runner,
                                authorized_line: box && DevBox.authorized_keys_line(box["public_key"], forced: BOX != Runner),
                                csrf_save: csrf_tag("/devbox/save"),
                                csrf_test: csrf_tag("/devbox/test"),
                                csrf_prepare: csrf_tag("/devbox/prepare"),
                                csrf_rotate: csrf_tag("/devbox/rotate"),
                                csrf_delete: csrf_tag("/devbox/delete")},
          layout: false)
      end
    end

    r.on "sessions" do
      next r.redirect "/" unless REVIEWS_ENABLED

      # Tears down by box name, so a box the dashboard did not start can be
      # removed too. The name is validated before it is sent.
      r.post "teardown" do
        check_csrf!
        name = r.params["box"].to_s
        if name.empty?
          id = param_id(r.params["id"])
          row = id && DB.row("SELECT box_name FROM review_jobs WHERE login = $1 AND id = $2",
                             [current_login, id])
          name = row ? row["box_name"].to_s : ""
        end
        box = DB.row("SELECT * FROM dev_boxes WHERE login = $1", [current_login])

        if name.empty? || box.nil?
          session["sessions_error"] = "no such box, or no dev box registered"
        elsif !name.match?(DevBox::BOX_RE)
          session["sessions_error"] = "bad box name"
        else
          res = BOX.run(box, "teardown #{name}")
          # Whether or not it worked, what we remember about this box's list is
          # no longer trustworthy.
          BOX.forget_box_list(box)
          if res[:ok]
            # Say so. A teardown that works and one that silently does nothing
            # looked identical before.
            Jobs.mark_torn_down(current_login, name)
            session["sessions_notice"] = "tore down #{name}. That pull request can be reviewed again."
          else
            detail = (res[:error] || res[:output]).to_s.strip
            session["sessions_error"] = "could not tear down #{name}: #{detail[0, 400]}"
          end
        end
        r.redirect "/sessions"
      end

      # A follow-up question in the box that already ran the review.
      r.post "ask" do
        check_csrf!
        prompt = r.params["prompt"].to_s.strip
        id = param_id(r.params["id"])
        job = id && DB.row("SELECT * FROM review_jobs WHERE login = $1 AND id = $2",
                           [current_login, id])
        box = job && Jobs.dev_box(job)

        if prompt.empty?
          session["sessions_error"] = "type a question first"
        elsif prompt.bytesize > 8192
          session["sessions_error"] = "that question is too long (8 KB limit)"
        elsif job.nil? || box.nil?
          session["sessions_error"] = "no such review, or no dev box registered"
        elsif !%w[done failed].include?(job["state"])
          session["sessions_error"] = "wait for the review to finish first"
        else
          # Reopen FIRST. reopen re-enters review_jobs_live_idx, so it can lose
          # to another live job for the same pull request; firing the ask before
          # knowing that left the box answering into a row that was never
          # reopened, and raised a 500 on the way out.
          reopened = begin
            Jobs.reopen(job["id"], current_login)
          rescue PG::UniqueViolation
            nil
          end

          if reopened.nil?
            session["sessions_error"] =
              "another review is already running for that pull request; wait for it to finish"
          else
            # The question goes over stdin, so it is never part of a command line.
            res = BOX.run(box, "ask #{job["box_name"]}", stdin: prompt)
            unless res[:ok]
              detail = (res[:error] || res[:output]).to_s.strip
              Jobs.finish(job["id"], "failed", error: "could not ask: #{detail[0, 400]}")
              session["sessions_error"] = "could not ask: #{detail[0, 400]}"
            end
          end
        end
        r.redirect "/sessions"
      end

      # Deletes the record and its review text. Only offered once the box is
      # gone, so nothing live can be forgotten by accident.
      r.post "forget" do
        check_csrf!
        if (id = param_id(r.params["id"]))
          DB.exec(<<~SQL, [current_login, id])
            DELETE FROM review_jobs
            WHERE login = $1 AND id = $2 AND torn_down_at IS NOT NULL
          SQL
        end
        r.redirect "/sessions"
      end

      r.post "cancel" do
        check_csrf!
        if (id = param_id(r.params["id"]))
          Jobs.cancel(login: current_login, id: id)
        end
        r.redirect "/sessions"
      end

      # Byte-offset tail. Returns only what is new, so a browser can follow a
      # running review with short requests instead of holding a thread open for
      # the five minutes a box takes.
      #
      # The slice is taken in Postgres rather than here. This runs every two
      # seconds for as long as a review is open in a browser, and a review is
      # capped at 200 KB, so selecting the column and cutting it in Ruby shipped
      # the whole log across the network on every poll -- usually to answer
      # "nothing new yet".
      # The live log, streamed.
      #
      # bay runs here now, so a review writes its output to a file on this host.
      # The page reads that file as it grows, instead of waiting for the worker
      # to notice (up to 3s) and then the browser to poll (2s). Text arrives as
      # claude writes it.
      #
      # Bounded on both axes: MAX_STREAMS at once, and each ends after
      # STREAM_SECONDS. EventSource reconnects on its own, so an ending stream
      # is invisible to the reader and a refused browser simply retries.
      r.get "stream" do
        id = param_id(r.params["id"])
        job = id && DB.row("SELECT box_name FROM review_jobs WHERE login = $1 AND id = $2",
                           [current_login, id])
        # 204 means "not available": the client falls back to polling rather
        # than retrying a stream that will never exist. The body must be a
        # string -- returning the status number makes Roda answer 500.
        nothing = lambda do |code|
          response.status = code
          ""
        end
        next nothing.call(204) unless job && BOX.respond_to?(:log_path)
        path = BOX.log_path(current_login, job["box_name"])
        next nothing.call(204) unless path
        # 503 means "busy, try again": every stream slot is taken.
        next nothing.call(503) unless stream_slot

        response["Content-Type"] = "text/event-stream"
        response["Cache-Control"] = "no-store"
        # nginx buffers a proxied response by default, which would hold every
        # line back until the stream ended -- the opposite of the point.
        response["X-Accel-Buffering"] = "no"
        offset = r.params["offset"].to_s.to_i
        offset = 0 if offset.negative?
        box_name = job["box_name"]
        login = current_login

        stream(loop: false) do |out|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STREAM_SECONDS
          # The log holds claude's raw events, one JSON object per line. The
          # cursor renders whole lines and keeps a partial one, because the
          # file is read wherever it happens to have got to.
          cursor = StreamRender::Cursor.new
          begin
            File.open(path, "rb") do |f|
              # An offset past the end means the log was replaced by a shorter
              # one, so send it whole rather than sending nothing for ever.
              offset = 0 if offset > f.size
              f.seek(offset)
              loop do
                chunk = f.read
                if chunk && !chunk.empty?
                  offset += chunk.bytesize
                  raw = chunk.force_encoding(Encoding::UTF_8).scrub("")
                  text = cursor.push(raw)
                  unless text.empty?
                    out << "event: log\ndata: #{JSON.generate(offset: offset, text: text)}\n\n"
                  end
                end
                state = BOX.state_word(login, box_name)
                if %w[done failed].include?(state)
                  rest = cursor.finish
                  out << "event: log\ndata: #{JSON.generate(offset: offset, text: rest)}\n\n" unless rest.empty?
                  out << "event: end\ndata: #{JSON.generate(state: state, offset: offset)}\n\n"
                  break
                end
                break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                sleep 0.4
              end
            end
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET
            # The reader navigated away. Not an error.
          ensure
            release_stream_slot
          end
        end
      end

      r.get "tail" do
        response["Content-Type"] = "application/json"
        response["Cache-Control"] = "no-store"
        id = param_id(r.params["id"])
        offset = r.params["offset"].to_s.to_i
        offset = 0 if offset.negative?
        # An offset past the end means the log was replaced by a shorter one, and
        # the answer is to send it again from the start -- not to send nothing,
        # which left the client frozen on stale text forever. An offset equal to
        # the length is simply caught up, and sends nothing.
        job = id && DB.row(<<~SQL, [current_login, id, offset])
          SELECT state, phase, octet_length(output) AS length,
                 substring(convert_to(output, 'UTF8')
                           FROM (CASE WHEN $3::bigint > octet_length(output) THEN 0
                                      ELSE $3::bigint END)::int + 1) AS chunk
          FROM review_jobs WHERE login = $1 AND id = $2
        SQL
        next '{"error":"not found"}' unless job

        # substring() on the bytea cuts at a byte offset, and the browser's
        # offset is a byte count, so they agree -- but a hand-typed offset can
        # still land inside a multibyte character. JSON.generate raises on
        # invalid UTF-8, and the client retries the same offset every two
        # seconds, so that became a permanent 500 loop. scrub drops the partial
        # sequence instead.
        chunk = job["chunk"].to_s.dup.force_encoding(Encoding::UTF_8)
        chunk = chunk.scrub("") unless chunk.valid_encoding?
        JSON.generate(state: job["state"], phase: job["phase"], length: job["length"].to_i,
                      chunk: chunk, done: !%w[queued running].include?(job["state"]))
      end

      # One stored review, for a panel that was not printed with the page.
      # Answers JSON to the script and a plain page to a browser without one,
      # so the same link works either way.
      r.get "review" do
        id = param_id(r.params["id"])
        text = id && Jobs.output(current_login, id)
        noise, review = Jobs.split_output(text)
        if r.params["format"] == "json"
          response["Content-Type"] = "application/json"
          response["Cache-Control"] = "no-store"
          next JSON.generate(found: !text.nil?, review: review, noise: noise)
        end
        view("review", locals: {id: id, found: !text.nil?, review: review, noise: noise},
          layout: false)
      end

      r.get true do
        jobs = Jobs.for_user(current_login)
        # Only the reviews this page is going to print. The rest carry their
        # size and load from /sessions/review when their panel is opened.
        outputs = Jobs.outputs(current_login, Jobs.inline_ids(jobs))
        box = DB.row("SELECT * FROM dev_boxes WHERE login = $1", [current_login])
        # Boxes outlive their reviews, so ask the dev box what actually exists
        # rather than trusting our own rows.
        boxes = box ? BOX.box_list(box) : []
        view("sessions", locals: {jobs: jobs, outputs: outputs, boxes: boxes, dev_box: box,
                                  login: current_login,
                                  error: session.delete("sessions_error"),
                                  notice: session.delete("sessions_notice"),
                                  csrf_teardown: csrf_tag("/sessions/teardown"),
                                  csrf_cancel: csrf_tag("/sessions/cancel"),
                                  csrf_ask: csrf_tag("/sessions/ask"),
                                  csrf_forget: csrf_tag("/sessions/forget")},
          layout: false)
      end
    end

    r.post "review" do
      check_csrf!
      if REVIEWS_ENABLED
        pr = param_id(r.params["pr"])
        if pr.nil?
          session["review_error"] = "that pull request number is not valid"
        else
          res = Jobs.enqueue(login: current_login, repo: r.params["repo"].to_s, pr_number: pr)
          # Never swallow this: pressing Review and seeing nothing happen is
          # worse than seeing an error.
          session["review_error"] = res[:error] unless res[:ok]
        end
      end
      r.redirect "/?#{r.query_string}"
    end

    r.post "settings" do
      check_csrf!
      session["label"] = QueueService.clean_label(r.params["label"])
      r.redirect "/?#{r.query_string}"
    end

    r.post "snooze" do
      check_csrf!
      key = r.params["key"].to_s
      unless key.empty?
        session["snoozed"] = Snooze.new(session["snoozed"]).add(key, SNOOZE_SECONDS).to_h
      end
      r.redirect "/?#{r.query_string}"
    end

    r.post "unsnooze" do
      check_csrf!
      key = r.params["key"].to_s
      session["snoozed"] = Snooze.new(session["snoozed"]).remove(key).to_h unless key.empty?
      r.redirect "/?#{r.query_string}"
    end

    r.root do
      snap = service.snapshot

      # A dead token is the one error a user can actually clear, and the banner
      # left them to work out how. GitHub already knows this browser, so the
      # round trip is usually invisible: back here, signed in, queue drawn.
      #
      # Guarded by when the token was issued. One minted seconds ago that is
      # already refused will be refused again, and without the guard the page
      # would bounce through GitHub forever. Past that window the banner
      # stands, because that failure is not a stale session.
      if snap[:unauthorized] && Time.now.to_i - session["authed_at"].to_i > REAUTH_GRACE
        REGISTRY.forget(current_login)
        session.delete("token")
        next r.redirect "/auth/start"
      end

      # .to_sym on a raw param raises NoMethodError for ?tab[]=all, and every
      # redirect re-appends the query string, so the 500 followed the user
      # around. Coerce, then accept only a tab that exists.
      known = service.tabs.map { |t| t[:key] }
      asked = r.params["tab"].to_s.to_sym
      tab = known.include?(asked) ? asked : :all
      hide = r.params["hide"] == "1"

      # sweep first: it wakes every row that expired or that has new activity.
      snooze = Snooze.new(session["snoozed"]).sweep(snap[:rows])
      session["snoozed"] = snooze.to_h

      awake = snap[:rows].reject { |row| snooze.hidden?(row) }
      asleep = snap[:rows].select { |row| snooze.hidden?(row) }

      # Merged rows are a separate list on the snapshot, not part of the queue,
      # so snoozing and Hide settled do not apply to them. They are all settled
      # by definition, and there is nothing left to hide.
      merged = snap[:merged] || []

      if tab == :snoozed
        rows = asleep
      elsif tab == :merged
        rows = merged
      else
        rows = awake.select { |row| tab == :all || row[:buckets].include?(tab) }
        rows = rows.reject { |row| row[:settled] } if hide
      end

      # Counts come from the awake rows only, or the tab badges show work that
      # the user cannot see.
      counts = service.counts(awake)
      counts[:snoozed] = {open: asleep.count { |row| !row[:settled] }, total: asleep.size}
      # No open count: nothing merged is open, and "0/10" reads as a warning.
      counts[:merged] = {open: nil, total: merged.size}
      snap = snap.merge(counts: counts)

      view("queue", locals: {snap: snap, rows: rows, tab: tab, hide: hide, service: service,
                             login: current_login, csrf: csrf_tag("/refresh"),
                             csrf_logout: csrf_tag("/logout"),
                             csrf_snooze: csrf_tag("/snooze"),
                             csrf_settings: csrf_tag("/settings"),
                             suggested_label: SUGGESTED_LABEL,
                             reviews_enabled: REVIEWS_ENABLED,
                             review_error: session.delete("review_error"),
                             has_dev_box: (REVIEWS_ENABLED &&
                               !DB.row("SELECT 1 FROM dev_boxes WHERE login = $1", [current_login]).nil?),
                             csrf_review: csrf_tag("/review"),
                             jobs_by_key: (REVIEWS_ENABLED ? Jobs.by_key(current_login) : {}),
                             csrf_unsnooze: csrf_tag("/unsnooze"),
                             snooze: snooze},
        layout: false)
    end
  end
end
