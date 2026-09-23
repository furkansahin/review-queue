#!/usr/bin/env ruby
# Expired-session tests:  bundle exec ruby test_reauth.rb
#
# A GitHub token dies two ways: the user removes the app, or it goes a year
# unused. Both surface as 401 Bad credentials, which the page used to print as
# a banner nobody could act on.
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_REAUTH_GRACE"]         = "1"   # seconds; the test sits on both sides of it
require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end

# The world. Two separate switches, because a sign-in and a queue rebuild are
# separate calls and the interesting case is one working while the other does
# not -- that is what the loop guard is for.
WORLD = {login: "furkansahin", signin_dead: false, queue_dead: false, exchanges: 0}
GitHubOAuth.class_eval do
  define_method(:exchange) { |_| WORLD[:exchanges] += 1; "gho_#{WORLD[:exchanges]}" }
end
GitHubClient.class_eval do
  define_method(:get) do |path|
    raise GitHubClient::Unauthorized, "GitHub 401 on #{path}: Bad credentials" if WORLD[:signin_dead]
    {"login" => WORLD[:login]}
  end
end
QueueService.class_eval do
  define_method(:build) do
    raise GitHubClient::Unauthorized, "GitHub 401 on /user: Bad credentials" if WORLD[:queue_dead]
    rows = [{key: "ubicloud/ubicloud#1", repo: "ubicloud", repo_full: "ubicloud/ubicloud",
             number: 1, last_at: Time.now - 3600, buckets: [:review], settled: false,
             sort_key: [0, 0], draft: false, url: "u", title: "t", ref: "ubicloud #1",
             author: "someone", state: "To review", state_bg: "x", state_color: "y",
             row_bg: "z", age_color: "a", age_text_color: "b", age: "1h",
             last_who: "someone", last_what: "comment · 1h ago", my_action: "never",
             my_action_kind: nil, quick: false, churn: 10, changed: 1,
             read_est: "~1m", size_sub: "±10 · 1f", ci: "pass", ci_color: "c", chips: []}]
    {rows: rows, counts: counts(rows), login: WORLD[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: {count: 0, complete: true}}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app

def sign_in
  get "/auth/start"
  state = last_response.location[/state=([^&]+)/, 1]
  get "/auth/callback?code=c&state=#{state}"
end
def csrf(path) = last_response.body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

puts "-- a live token behaves as before --"
sign_in
get "/"
check("the queue renders", last_response.status, 200)

puts "-- a token that has since died sends the user through GitHub --"
# It dies long after it was issued, so age this session past the grace. The
# stamp is whole seconds, so the wait has to cross two boundaries.
sleep 2.2
WORLD[:queue_dead] = true
REGISTRY.forget("furkansahin")
get "/"
check("no banner, a redirect", last_response.status, 302)
check("to the sign-in", last_response.location, "/auth/start")
check("the dead token is dropped", last_request.session["token"], nil)
get "/auth/start"
check("which hands off to GitHub", last_response.location.to_s.start_with?("https://github.com/login/oauth"), true)

puts "-- and it does not loop when a fresh token does not help --"
# Sign-in works, the queue still 401s. Without the guard the page would send
# the user straight back to GitHub, for ever.
before = WORLD[:exchanges]
sign_in
check("the callback lands on the queue", last_response.location, "/")
get "/"
check("the banner stands this time", last_response.status, 200)
check("saying what GitHub said", last_response.body.include?("Bad credentials"), true)
check("and GitHub was asked exactly once", WORLD[:exchanges] - before, 1)

puts "-- a sign-in that cannot succeed says so, rather than bouncing --"
WORLD[:signin_dead] = true
sign_in
check("the callback shows the failure", last_response.body.include?("GitHub sign-in failed"), true)
WORLD[:signin_dead] = false

puts "-- once the token works again, so does the page --"
WORLD[:queue_dead] = false
sign_in
REGISTRY.forget("furkansahin")
get "/"
check("no redirect", last_response.status, 200)
check("no banner", last_response.body.include?("Bad credentials"), false)

puts "-- signing in again keeps what the session was holding --"
# label and snoozed live only in the session, so a token refresh that cleared
# them would silently throw away every row the user had put out of sight.
post "/settings", {"label" => "clickhouse", "_csrf" => csrf("/settings")}
get "/"
check("the label is set", last_response.body.include?('value="clickhouse"'), true)
post "/snooze", {"key" => "ubicloud/ubicloud#1", "_csrf" => csrf("/snooze")}
get "/"
snoozed_before = last_request.session["snoozed"]
check("something is snoozed", snoozed_before.to_h.size, 1)

sign_in   # the same person, a new token
get "/"
check("the watch label survived", last_response.body.include?('value="clickhouse"'), true)
check("and so did the snooze list", last_request.session["snoozed"], snoozed_before)
check("on a genuinely new token", last_request.session["token"], "gho_#{WORLD[:exchanges]}")

puts "-- but a different person inherits nothing --"
WORLD[:login] = "mohi-kalantari"
sign_in
get "/"
check("not the previous user's label", last_response.body.include?('value="clickhouse"'), false)
check("nor their snooze list", last_request.session["snoozed"].to_h.size, 0)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
