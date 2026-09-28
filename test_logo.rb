#!/usr/bin/env ruby
# The drop in the logo, filled as the queue is:  bundle exec ruby test_logo.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"

require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

puts "-- the levels --"
check("fuller is higher, all the way up", Logo::LEVELS.each_cons(2).all? { |a, b| b < a }, true)
check("empty shows nothing: the surface is below the drop", Logo.level(0) > 59, true)
check("full leaves no dry tip", Logo.level(100) < 5, true)
check("the mark as drawn is a quarter full", Logo.level(nil), Logo.level(25))
check("which is where it was drawn", (Logo.level(25) - 46).abs < 0.5, true)
# By area: a tenth of the water sits well above a tenth of the height, since
# the bottom is the wide part.
check("by area, not height", Logo.level(10) < 59 - (0.1 * 54), true)
check("a little waiting is still enough water to see", Logo.level(1), Logo.level(Logo::MIN_SHOWN))

puts "-- the tab icon --"
include Rack::Test::Methods
def app = ReviewQueue.app
get "/favicon.svg?fill=0"
check("empty", last_response.body.include?(Logo.water(0)), true)
get "/favicon.svg?fill=100"
check("full", last_response.body.include?(Logo.water(100)), true)
get "/favicon.svg?fill=250"
check("past full is full", last_response.body.include?(Logo.water(100)), true)
get "/favicon.svg?fill=abc"
check("nonsense is the mark as drawn", last_response.body.include?(Logo.water(nil)), true)
check("and caches", last_response.headers["Cache-Control"], "public, max-age=86400")

puts "-- the header drop --"
a, b = Logo.svg(20, fill: 40), Logo.svg(20, fill: 40)
check("each drop clips by its own id", a[/id="(lw\h+)c"/, 1] != b[/id="(lw\h+)c"/, 1], true)
check("no motion without a level to come from", a.include?("@keyframes"), false)
check("nor when it has not changed", Logo.svg(20, fill: 40, from: 40).include?("@keyframes"), false)
moving = Logo.svg(20, fill: 20, from: 60)
check("a change drains from the old level", moving.include?("translateY(#{(Logo.level(60) - Logo.level(20)).round(1)}px)"), true)
check("unless the viewer asked for less motion", moving.include?("prefers-reduced-motion:no-preference"), true)

puts "-- the queue fills it --"
ROWS = []
def row(n, settled: false, draft: false)
  {key: "o/r##{n}", last_at: Time.now - 3600, settled: settled, draft: draft, buckets: [:review], quick: false,
   url: "https://github.com/o/r/pull/#{n}", title: "PR #{n}", ref: "o/r ##{n}", author: "someone",
   state: settled ? "Waiting on them" : "Your turn", state_bg: "var(--x)", state_color: "var(--x)", chips: [],
   row_bg: "var(--row)", age_color: "var(--x)", age_text_color: "var(--x)", age: "1h", read_est: "~1m",
   size_sub: "±5 · 1f", last_who: "someone", last_what: "comment", my_action: "never", my_action_kind: nil,
   ci: "pass", ci_color: "var(--ci-pass)", repo_full: "o/r", number: n}
end
ERR = [nil]
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: ROWS.dup, counts: counts(ROWS), login: "furkansahin", fetched_at: Time.now, rate: 5000, error: ERR[0],
     reviews_7d: {count: 0, complete: true}, merged: [], issues: []}
  end
end
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

# Two waiting, one settled, one draft: the draft counts in neither.
ROWS.replace([row(1), row(2), row(3, settled: true), row(4, draft: true)])
get "/"
page = last_response.body
check("the tab icon shows two of three", page.include?('href="/favicon.svg?fill=67"'), true)
check("so does the header", page.include?(Logo.water(67)), true)
check("and says it in words", page.include?('title="2 of 3 still waiting on you"'), true)
check("the first time, nothing moves", page.match?(/@keyframes lw\h+a/), false)
get "/?tab=quick"
check("whichever tab is open", last_response.body.include?('href="/favicon.svg?fill=67"'), true)

# One reviewed: it drains from where it was.
ROWS.replace([row(1), row(2, settled: true), row(3, settled: true)])
get "/"
page = last_response.body
check("then one of three", page.include?('href="/favicon.svg?fill=33"'), true)
check("draining from two of three", page.include?("translateY(#{(Logo.level(67) - Logo.level(33)).round(1)}px)"), true)

puts "-- the other pages show what the queue last did --"
get "/sessions"
check("the sessions page's tab icon", last_response.body.include?('href="/favicon.svg?fill=33"'), true)
check("and its header", last_response.body.include?(Logo.water(33)), true)

puts "-- and when there is nothing to show --"
ERR[0] = "GitHub is down"
ROWS.clear
get "/"
check("a failing GitHub is not a clear queue", last_response.body.include?('href="/favicon.svg?fill=33"'), true)
ERR[0] = nil
get "/"
check("a clear one is empty", last_response.body.include?('href="/favicon.svg?fill=0"'), true)
check("and says so", last_response.body.include?("Nothing waiting on you: the drop is empty"), true)
ROWS.replace([row(1)])
get "/"
check("one of one is full", last_response.body.include?('href="/favicon.svg?fill=100"'), true)
ROWS.replace([row(1)] + (2..300).map { |n| row(n, settled: true) })
get "/"
check("anything waiting shows, however little", last_response.body.include?('href="/favicon.svg?fill=1"'), true)
post "/logout", {"_csrf" => last_response.body[/action="\/logout"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"/m, 1]}
get "/login"
check("signed out, the mark as drawn", last_response.body.include?('href="/favicon.svg"') &&
                                        last_response.body.include?(Logo.water(nil)), true)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
