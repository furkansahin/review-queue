require "roda"
require "securerandom"
require_relative "queue_service"

def env_required(key)
  ENV[key] || abort("missing required env var #{key}")
end

SERVICE = QueueService.new(
  token: env_required("GITHUB_TOKEN"),
  scope: ENV.fetch("RQ_SCOPE", "repo:ubicloud/ubicloud"),
  label: ENV.fetch("RQ_LABEL", "clickhouse"),
  warn_days: ENV.fetch("RQ_WARN_DAYS", "2").to_i,
  hot_days: ENV.fetch("RQ_HOT_DAYS", "4").to_i,
  stale_days: ENV.fetch("RQ_STALE_DAYS", "7").to_i,
  ttl: ENV.fetch("RQ_CACHE_TTL", "300").to_i,
  quick_lines: ENV.fetch("RQ_QUICK_LINES", "50").to_i,
  lines_per_min: ENV.fetch("RQ_LINES_PER_MIN", "20").to_i
)

AUTH_USER = ENV.fetch("RQ_USER", "me")
AUTH_PASS = env_required("RQ_PASSWORD")

class ReviewQueue < Roda
  plugin :render, engine: "erb", views: File.expand_path("views", __dir__), escape: true
  plugin :default_headers,
    "Content-Type" => "text/html; charset=utf-8",
    "X-Frame-Options" => "DENY",
    "X-Content-Type-Options" => "nosniff",
    "Referrer-Policy" => "no-referrer"

  def authorized?
    header = request.env["HTTP_AUTHORIZATION"].to_s
    return false unless header.start_with?("Basic ")
    user, _, pass = header.sub("Basic ", "").unpack1("m").to_s.partition(":")
    ok = user.bytesize == AUTH_USER.bytesize && pass.bytesize == AUTH_PASS.bytesize
    ok &&= secure_eq(user, AUTH_USER) & secure_eq(pass, AUTH_PASS)
    ok
  end

  def secure_eq(a, b)
    res = 0
    a.bytes.each_with_index { |byte, i| res |= byte ^ b.bytes[i].to_i }
    res.zero?
  end

  route do |r|
    r.get "healthz" do
      response["Content-Type"] = "text/plain"
      "ok"
    end

    unless authorized?
      response["WWW-Authenticate"] = 'Basic realm="review queue"'
      response.status = 401
      next "unauthorized"
    end

    r.post "refresh" do
      SERVICE.snapshot(force: true)
      r.redirect "/?#{r.query_string}"
    end

    r.root do
      snap = SERVICE.snapshot
      tab = (r.params["tab"] || "all").to_sym
      hide = r.params["hide"] == "1"
      rows = snap[:rows].select { |row| tab == :all || row[:buckets].include?(tab) }
      rows = rows.reject { |row| row[:settled] } if hide
      view("queue", locals: {snap: snap, rows: rows, tab: tab, hide: hide, service: SERVICE},
        layout: false)
    end
  end
end
