#!/usr/bin/env ruby
# Snooze route tests:  bundle exec ruby test_snooze_routes.rb
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"

require "rack/test"
require_relative "app"

NOW = Time.now
# last_at is mutable, so a test can simulate new activity on a snoozed row.
LAST = {"o/r#1" => NOW - 5 * 86_400, "o/r#2" => NOW - 2 * 86_400}

def mkrow(key, days)
  {key: key, last_at: LAST[key], settled: false, buckets: [:review], quick: false,
   url: "https://github.com/o/r/pull/#{key[-1]}", title: "PR #{key}", ref: key, author: "someone",
   state: "To review", state_bg: "var(--state-todo-bg)", state_color: "var(--state-todo-fg)",
   chips: [], row_bg: "var(--row)", age_color: "var(--age-stale-bar)",
   age_text_color: "var(--age-stale-fg)", age: "#{days}d", read_est: "~1m", size_sub: "±5 · 1f",
   last_activity: "#{days}d ago", last_actor: "someone", my_action: "never",
   my_action_kind: "no activity from you", ci: "pass", ci_color: "var(--ci-pass)"}
end

GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [mkrow("o/r#1", 5), mkrow("o/r#2", 2)], counts: {}, login: "furkansahin",
     fetched_at: NOW, rate: 5000, error: nil, reviews_7d: {count: 0, complete: true}}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-50s got=%-7s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="([^"]+)" value="([^"]+)"/m, 2]
def csrf_name(body) = body[/name="(_csrf)"/, 1] || "_csrf"
def rows_on_page(body) = body.scan(/name="key" value="([^"]+)"/).flatten.uniq

# sign in
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/"
check("both rows visible before snooze", rows_on_page(last_response.body).sort, ["o/r#1", "o/r#2"])
check("All tab count is 2", last_response.body[/All<\/span>\s*<span class="badge">(\d+)\/(\d+)/m, 2], "2")

# CSRF is required
post "/snooze", "key" => "o/r#1"
check("snooze without CSRF is blocked", last_response.status, 403)

# snooze row 1
get "/"
tok = csrf_for(last_response.body, "/snooze")
post "/snooze", {"key" => "o/r#1", csrf_name(last_response.body) => tok}
check("snooze redirects", last_response.status, 302)
get "/"
check("snoozed row is hidden", rows_on_page(last_response.body), ["o/r#2"])
check("All tab count drops to 1", last_response.body[/All<\/span>\s*<span class="badge">(\d+)\/(\d+)/m, 2], "1")
check("Snoozed tab count is 1", last_response.body[/Snoozed<\/span>\s*<span class="badge">(\d+)\/(\d+)/m, 2], "1")

# the snoozed tab shows it
get "/?tab=snoozed"
check("snoozed tab lists the row", rows_on_page(last_response.body), ["o/r#1"])
check("snoozed tab offers Wake", last_response.body.include?(">Wake<"), true)
check("no hero card on snoozed tab", last_response.body.include?("Next up"), false)

# new activity wakes it, with no user action
LAST["o/r#1"] = Time.now + 1
get "/"
check("new activity wakes the row", rows_on_page(last_response.body).sort, ["o/r#1", "o/r#2"])
LAST["o/r#1"] = NOW - 5 * 86_400

# unsnooze by hand
get "/"
tok = csrf_for(last_response.body, "/snooze")
post "/snooze", {"key" => "o/r#2", csrf_name(last_response.body) => tok}
get "/?tab=snoozed"
tok = csrf_for(last_response.body, "/unsnooze")
post "/unsnooze", {"key" => "o/r#2", csrf_name(last_response.body) => tok}
get "/"
check("wake button restores the row", rows_on_page(last_response.body).include?("o/r#2"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
