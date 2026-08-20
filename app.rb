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
  lines_per_min: ENV.fetch("RQ_LINES_PER_MIN", "20").to_i
)

SNOOZE_SECONDS = ENV.fetch("RQ_SNOOZE_DAYS", "7").to_i * 86_400

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
        session.clear
        session["login"] = login
        session["token"] = token
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

      r.post "save" do
        check_csrf!
        error = nil
        begin
          t = DevBox.check_target!(host: r.params["host"], ssh_user: r.params["ssh_user"],
                                   port: r.params["port"].to_s.empty? ? 22 : r.params["port"])
          if (row = current.call)
            # Keep the existing keypair: changing the address must not force the
            # user to reinstall the key.
            DB.exec("UPDATE dev_boxes SET host=$1, ssh_user=$2, port=$3 WHERE id=$4",
                    [t[:host], t[:ssh_user], t[:port], row["id"]])
          else
            priv, pub = DevBox.generate_keypair(comment: "review-queue:#{current_login}")
            DB.exec(<<~SQL, [current_login, t[:host], t[:ssh_user], t[:port], Crypto.encrypt(priv), pub])
              INSERT INTO dev_boxes (login, host, ssh_user, port, private_key_enc, public_key)
              VALUES ($1, $2, $3, $4, $5, $6)
            SQL
          end
        rescue DevBox::Error => e
          error = e.message
        end
        session["devbox_error"] = error
        r.redirect "/devbox"
      end

      r.post "test" do
        check_csrf!
        if (row = current.call)
          res = DevBox.check(row)
          if res[:ok]
            DB.exec("UPDATE dev_boxes SET last_ok_at = now(), last_error = NULL WHERE id = $1", [row["id"]])
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
                                wrapper_url: WRAPPER_URL,
                                authorized_line: box && DevBox.authorized_keys_line(box["public_key"]),
                                csrf_save: csrf_tag("/devbox/save"),
                                csrf_test: csrf_tag("/devbox/test"),
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
          res = DevBox.run(box, "teardown #{name}")
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
            res = DevBox.run(box, "ask #{job["box_name"]}", stdin: prompt)
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
      r.get "tail" do
        response["Content-Type"] = "application/json"
        response["Cache-Control"] = "no-store"
        id = param_id(r.params["id"])
        job = id && DB.row("SELECT id, state, phase, output FROM review_jobs WHERE login = $1 AND id = $2",
                           [current_login, id])
        next '{"error":"not found"}' unless job

        text = job["output"].to_s
        # Compare BEFORE clamping: clamp(0, bytesize) already caps the value, so
        # the shrink check below it could never fire and a client holding a large
        # offset against a replaced, shorter log sat frozen on stale text.
        asked = r.params["offset"].to_s.to_i
        offset = asked > text.bytesize ? 0 : asked.clamp(0, text.bytesize)
        # byteslice can split a character, and JSON.generate raises on invalid
        # UTF-8 -- which turned the tail into a permanent 500 loop, because the
        # client retries the same offset forever. scrub drops the partial bytes.
        chunk = text.byteslice(offset, text.bytesize - offset).to_s.scrub("")
        JSON.generate(state: job["state"], phase: job["phase"], length: text.bytesize,
                      chunk: chunk,
                      done: !%w[queued running].include?(job["state"]))
      end

      r.get true do
        jobs = Jobs.for_user(current_login)
        box = DB.row("SELECT * FROM dev_boxes WHERE login = $1", [current_login])
        # Boxes outlive their reviews, so ask the dev box what actually exists
        # rather than trusting our own rows.
        boxes = if box
          res = DevBox.run(box, "list")
          res[:ok] ? res[:output].to_s.lines.map { |l| l.strip.split("\t") }.reject(&:empty?) : []
        else
          []
        end
        view("sessions", locals: {jobs: jobs, boxes: boxes, dev_box: box, login: current_login,
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

      if tab == :snoozed
        rows = asleep
      else
        rows = awake.select { |row| tab == :all || row[:buckets].include?(tab) }
        rows = rows.reject { |row| row[:settled] } if hide
      end

      # Counts come from the awake rows only, or the tab badges show work that
      # the user cannot see.
      counts = service.counts(awake)
      counts[:snoozed] = {open: asleep.count { |row| !row[:settled] }, total: asleep.size}
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
