#!/usr/bin/env ruby
# What is broken, or about to be, shown before it bites:  bundle exec ruby test_health.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_SCOPE"]                = "repo:ubicloud/ubicloud"

require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

NOW = Time.utc(2026, 10, 7, 9, 0, 0)

puts "-- asking GitHub about a token --"
def answer_with(code, expires: nil, raise_it: false)
  res = Net::HTTPResponse::CODE_TO_OBJ[code].new("1.1", code, "x")
  res["github-authentication-token-expiration"] = expires if expires
  res.instance_variable_set(:@read, true)
  fake = Object.new
  fake.define_singleton_method(:request) { |_| raise Errno::ECONNREFUSED if raise_it; res }
  Net::HTTP.define_singleton_method(:start) { |*_, **_, &blk| blk.call(fake) }
end
answer_with("200", expires: "2026-10-16 14:19:33 UTC")
check("accepted, with its expiry", Health.check_token("t"), ["ok", Time.utc(2026, 10, 16, 14, 19, 33)])
answer_with("200")
check("accepted, and never expiring", Health.check_token("t"), ["ok", nil])
answer_with("401")
check("refused", Health.check_token("t"), ["refused", nil])
answer_with("502")
check("GitHub having trouble says nothing about the token", Health.check_token("t"), [nil, nil])
answer_with("200", raise_it: true)
check("nor does GitHub out of reach", Health.check_token("t"), [nil, nil])

puts "-- the worker's look --"
DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
DB.exec("DELETE FROM user_settings")
box = DB.row(<<~SQL, [Crypto.encrypt("github_pat_READ"), Crypto.encrypt("github_pat_WRITE")])
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key, github_token_enc, github_write_token_enc)
  VALUES ('furkansahin', '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA', $1, $2) RETURNING *
SQL
$answers = {"github_pat_READ" => ["ok", Time.utc(2026, 10, 16, 14, 19)], "github_pat_WRITE" => ["refused", nil]}
$asked = []
Health.singleton_class.prepend(Module.new { def check_token(t) = ($asked << t; $answers[t]) })
$box_ok = {ok: true}
Health.tick(check_box: ->(_) { $box_ok })
row = DB.row("SELECT * FROM bayboxes")
check("both tokens asked about", $asked.sort, %w[github_pat_READ github_pat_WRITE])
check("and what GitHub said, kept", row.values_at("read_token_state", "write_token_state"), %w[ok refused])
check("with the expiry", row["read_token_expires_at"].utc, Time.utc(2026, 10, 16, 14, 19))
check("the box was reached", row["last_error"], nil)
$asked.clear
Health.tick(check_box: ->(_) { $box_ok })
check("not asked again for six hours", $asked, [])
DB.exec("UPDATE bayboxes SET health_checked_at = now() - interval '7 hours'")
$answers = {"github_pat_READ" => [nil, nil], "github_pat_WRITE" => ["refused", nil]}
$box_ok = {ok: false, error: "ssh: connect to host 203.0.113.10 port 22: Connection timed out"}
Health.tick(check_box: ->(_) { $box_ok })
row = DB.row("SELECT * FROM bayboxes")
check("GitHub unreachable: what was known stays", [row["read_token_state"], row["read_token_expires_at"]&.utc], ["ok", Time.utc(2026, 10, 16, 14, 19)])
check("a box that cannot be reached is written down", row["last_error"].to_s.include?("Connection timed out"), true)

puts "-- what the page says --"
lines = Health.problems("furkansahin", now: NOW)
texts = lines.map { |l| l[:text] }
check("errors first", lines.map { |l| l[:level] }, [:error, :error, :warn])
check("a refused token stops things, and says which", texts[0].start_with?("GitHub refuses your write token"), true)
check("an unreachable box", texts[1].include?("Your box could not be reached") && texts[1].include?("timed out"), true)
check("a token expiring within two weeks, with the date", texts[2], "Your read token expires in 9 days (Oct 16): renew it, and paste the new one on the Baybox page, " \
                                                                       "before reviews, mornings and learning your review voice stop.")
DB.exec("UPDATE bayboxes SET write_token_state = 'ok', last_error = NULL")
check("more than two weeks out is not worth a line",
      Health.problems("furkansahin", now: Time.utc(2026, 9, 30)).map { |l| l[:text] }, [])
check("the day before, tomorrow", Health.problems("furkansahin", now: Time.utc(2026, 10, 15, 12)).first[:text].include?("expires tomorrow"), true)
check("the day itself, today", Health.problems("furkansahin", now: Time.utc(2026, 10, 16, 9)).first[:text].include?("expires today"), true)
check("past it, it has stopped", Health.problems("furkansahin", now: Time.utc(2026, 10, 17)).first.values_at(:level, :href),
      [:error, "/baybox"])
check("and says when", Health.problems("furkansahin", now: Time.utc(2026, 10, 17)).first[:text].include?("expired Oct 16"), true)

DB.exec("UPDATE bayboxes SET read_token_expires_at = NULL")
Prereview.save("furkansahin", on: true, hour: 7, count: 3, tz: "Europe/Amsterdam")
DB.exec("UPDATE user_settings SET prereview_last_on = '2026-10-07', prereview_note = '2026-10-07 05:00 UTC: not prepared: add a GitHub read token on the Baybox page'")
check("a morning that did not run", Health.problems("furkansahin", now: NOW).first[:text],
      "This morning's reviews were not started: add a GitHub read token on the Baybox page")
check("not a week later", Health.problems("furkansahin", now: NOW + 5 * 86_400), [])
DB.exec("UPDATE user_settings SET prereview_note = '2026-10-07 05:00 UTC: prepared #6563'")
check("one that did is not a problem", Health.problems("furkansahin", now: NOW), [])

Voice.failed("furkansahin", "could not read your recent review comments: GitHub 401")
check("voice learning failing", Health.problems("furkansahin").first[:text], "Learning your review voice is failing: could not read your recent review comments: GitHub 401")
Voice.failed("furkansahin", nil)
check("and cleared by the next success", Health.problems("furkansahin"), [])
check("approvals that could not be read",
      Health.problems("furkansahin", snap: {decisions_error: "GitHub GraphQL: something"}).first[:text].start_with?("Could not read approvals"), true)
check("someone with no box is told nothing about one", Health.problems("mohi-kalantari"), [])

puts "-- through the app --"
include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
SNAP_ERR = [nil]
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: "furkansahin", fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: [], decisions_error: SNAP_ERR[0]}
  end
end
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/"
check("all well: no line at all", last_response.body.include?('class="health"'), false)
DB.exec("UPDATE bayboxes SET write_token_state = 'refused'")
SNAP_ERR[0] = "GitHub GraphQL: timeout"
get "/"
page = last_response.body
check("a problem: a line at the top of the queue", page.include?('class="health-line error"') && page.include?("GitHub refuses your write token"), true)
check("with the way to fix it", page.include?(%(<a href="/baybox">fix it →</a>)), true)
check("and the approvals one too", page.include?("Could not read approvals from GitHub"), true)
check("above the tabs", page.index('class="health"') < page.index('<div class="tabs">'), true)
DB.exec("UPDATE bayboxes SET read_token_expires_at = '2026-10-16 14:19:00+00'")
get "/baybox"
check("the Baybox page says when each token expires", last_response.body.include?("read token: expires Oct 16 2026"), true)
check("and which is refused", last_response.body.include?("write token: refused by GitHub"), true)
tok = last_response.body[%r{action="/baybox/save"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1]
post "/baybox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22", "github_write_token" => "github_pat_NEW", "_csrf" => tok}
row = DB.row("SELECT * FROM bayboxes")
check("a new token is looked at again within the minute", [row["health_checked_at"], row["write_token_state"]], [nil, nil])
check("so the old warning goes with it", (get("/"); last_response.body.include?("GitHub refuses your write token")), false)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
