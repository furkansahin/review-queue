require "roda"
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
  DB.setup!
end

def env_required(key)
  ENV[key] || abort("missing required env var #{key}")
end

# Global defaults: every signed-in user watches the same scope and label.
REGISTRY = ServiceRegistry.new(
  idle_ttl: ENV.fetch("RQ_IDLE_TTL", "3600").to_i,
  max_users: ENV.fetch("RQ_MAX_USERS", "25").to_i,
  scope: ENV.fetch("RQ_SCOPE", "repo:ubicloud/ubicloud"),
  warn_days: ENV.fetch("RQ_WARN_DAYS", "2").to_i,
  hot_days: ENV.fetch("RQ_HOT_DAYS", "4").to_i,
  stale_days: ENV.fetch("RQ_STALE_DAYS", "7").to_i,
  ttl: ENV.fetch("RQ_CACHE_TTL", "300").to_i,
  quick_lines: ENV.fetch("RQ_QUICK_LINES", "50").to_i,
  lines_per_min: ENV.fetch("RQ_LINES_PER_MIN", "20").to_i
)

SNOOZE_SECONDS = ENV.fetch("RQ_SNOOZE_DAYS", "7").to_i * 86_400

# Only a hint in the settings box. It is deliberately NOT applied as a default:
# a shared default is what made every user inherit one person's topic feed.
SUGGESTED_LABEL = ENV.fetch("RQ_LABEL", "")

# Fails closed: with no allowlist nobody gets in, rather than everybody.
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
  plugin :default_headers,
    "Content-Type" => "text/html; charset=utf-8",
    "X-Frame-Options" => "DENY",
    "X-Content-Type-Options" => "nosniff",
    "Referrer-Policy" => "no-referrer"

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

    r.on "sessions" do
      next r.redirect "/" unless REVIEWS_ENABLED

      r.post "teardown" do
        check_csrf!
        id = r.params["id"].to_s
        job = DB.row("SELECT * FROM review_jobs WHERE login = $1 AND id = $2", [current_login, id])
        if job && (box = Jobs.dev_box(job))
          DevBox.run(box, "teardown #{job["box_name"]}")
        end
        r.redirect "/sessions"
      end

      r.post "cancel" do
        check_csrf!
        Jobs.cancel(login: current_login, id: r.params["id"].to_s)
        r.redirect "/sessions"
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
                                  csrf_teardown: csrf_tag("/sessions/teardown"),
                                  csrf_cancel: csrf_tag("/sessions/cancel")},
          layout: false)
      end
    end

    r.post "review" do
      check_csrf!
      if REVIEWS_ENABLED
        Jobs.enqueue(login: current_login, repo: r.params["repo"].to_s,
                     pr_number: r.params["pr"].to_s.to_i)
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
      tab = (r.params["tab"] || "all").to_sym
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
                             csrf_review: csrf_tag("/review"),
                             jobs_by_key: (REVIEWS_ENABLED ? Jobs.by_key(current_login) : {}),
                             csrf_unsnooze: csrf_tag("/unsnooze"),
                             snooze: snooze},
        layout: false)
    end
  end
end
