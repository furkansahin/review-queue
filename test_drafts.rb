#!/usr/bin/env ruby
# Drafts are not the queue -- they have a tab of their own:  bundle exec ruby test_drafts.rb
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
  puts format("  %s  %-54s got=%-26s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 26], want.inspect[0, 26])
end

def row(n, bucket: :review, settled: false, draft: false)
  {key: "o/r##{n}", last_at: Time.now - 3600, settled: settled, draft: draft, buckets: [bucket], quick: false,
   url: "https://github.com/o/r/pull/#{n}", title: "PR #{n}", ref: "o/r ##{n}", author: "someone",
   state: settled ? "Waiting on them" : "Your turn", state_bg: "var(--x)", state_color: "var(--x)",
   chips: [], row_bg: "var(--row)", age_color: "var(--x)", age_text_color: "var(--x)", age: "1h", read_est: "~1m",
   size_sub: "±5 · 1f", last_who: "someone", last_what: "comment", my_action: "never", my_action_kind: nil,
   ci: "pass", ci_color: "var(--ci-pass)", repo_full: "o/r", number: n}
end
ROWS = [row(1), row(2, settled: true), row(3, draft: true), row(4, bucket: :mine, draft: true),
        row(5, bucket: :mine), row(6, settled: true, draft: true)]
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: ROWS.dup, counts: counts(ROWS), login: "furkansahin", fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: []}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app
def listed(body = last_response.body) = body.scan(/name="key" value="o\/r#(\d+)"/).flatten.map(&:to_i).uniq.sort
def badge(label, body = last_response.body) = body[%r{<span>#{label}</span>\s*<span class="badge">([^<]+)</span>}, 1]
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

puts "-- the queue has no drafts --"
get "/"
check("All lists no draft", listed, [1, 2, 5])
check("nor counts one", badge("All"), "2/3")
check("the tab title counts what is to go", last_response.body[%r{<title>([^<]+)</title>}, 1], "(2) Leeghwater")
check("and so does the bar", last_response.body.include?(">2 to go</span>"), true)
check("the drop: two waiting of three", last_response.body.include?('href="/favicon.svg?fill=67"'), true)
get "/?tab=mine"
check("your own drafts leave My PRs too", listed, [5])
check("and its count", badge("My PRs"), "1/1")

puts "-- they have a tab of their own --"
check("a Drafts tab, after Quick wins", last_response.body.index(">Quick wins<").to_i < last_response.body.index(">Drafts<").to_i, true)
check("counting the drafts", badge("Drafts"), "2/3")
get "/?tab=drafts"
check("listing every draft, yours too", listed, [3, 4, 6])
check("with no progress bar: it is not the queue", last_response.body.include?(" to go</span>"), false)
check("nor a celebration", last_response.body.include?("🎉"), false)
check("nor a count in the tab title", last_response.body[%r{<title>([^<]+)</title>}, 1], "Leeghwater")
check("the drop still holds the queue", last_response.body.include?('href="/favicon.svg?fill=67"'), true)
get "/?tab=drafts&hide=1"
check("Hide settled works here too", listed, [3, 4])

puts "-- snoozing, and none at all --"
get "/?tab=drafts"
tok = last_response.body[%r{action="/snooze[^"]*"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1]
post "/snooze?tab=drafts", {"key" => "o/r#3", "_csrf" => tok}
get "/?tab=drafts"
check("a snoozed draft is out of sight", listed, [4, 6])
ROWS.reject! { |r| r[:draft] }
get "/?tab=drafts"
check("no drafts says so", last_response.body.include?("No draft pull requests."), true)
check("and does not celebrate it", last_response.body.include?("🎉"), false)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
