#!/usr/bin/env ruby
# Reviews prepared on weekday mornings:  bundle exec ruby test_prereview.rb
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
require "time"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

REPO = "ubicloud/ubicloud"
def row(n, state: "To review", draft: false, last_at: Time.now - 86_400)
  {key: "#{REPO}##{n}", repo_full: REPO, number: n, state: state, draft: draft, last_at: last_at}
end

# The queue as GitHub would give it, and which token asked for it.
$queue = {rows: [], error: nil, login: "furkansahin"}
$tokens = []
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    $tokens << @gh.instance_variable_get(:@token)
    $queue.merge(fetched_at: Time.now)
  end
end

DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
DB.exec("DELETE FROM user_settings")
def boxrow(login, read: "github_pat_READ")
  DB.row(<<~SQL, [login, read && Crypto.encrypt(read)])
    INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key, github_token_enc)
    VALUES ($1, '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA', $2) RETURNING *
  SQL
end
boxrow("furkansahin")
def on(login, tz: "Europe/Amsterdam", hour: 7, count: 3, enabled: true)
  check("(saved for #{login})", Prereview.save(login, on: enabled, hour: hour, count: count, tz: tz), nil)
  DB.exec("UPDATE user_settings SET prereview_last_on = NULL WHERE login = $1", [login])
end
def due(at) = Prereview.claim_due(Time.parse(at)).map { |r| r["login"] }

puts "-- whose morning it is --"
on("furkansahin")
check("off by default", Prereview.settings("mohi-kalantari")["prereview_on"], false)
check("before seven there, not yet", due("2026-10-05T04:59:00Z"), [])
check("seven in Amsterdam, a Monday: now", due("2026-10-05T05:30:00Z"), ["furkansahin"])
check("and only once that morning", due("2026-10-05T06:30:00Z"), [])
check("the next morning again, still within the hour's window", due("2026-10-06T07:30:00Z"), ["furkansahin"])
check("but not once the morning is over", due("2026-10-07T08:00:00Z"), [])
check("nor on a Saturday", due("2026-10-10T05:30:00Z"), [])
on("mohi-kalantari", tz: "America/New_York")
check("seven in New York is noon in Amsterdam", due("2026-10-08T11:05:00Z"), ["mohi-kalantari"])
on("furkansahin", enabled: false)
check("switched off, never", due("2026-10-09T05:30:00Z"), [])

puts "-- which pull requests --"
picked = Prereview.pick([row(1, state: "Your turn"), row(2), row(3, draft: true), row(4, state: "Reviewed"),
                         row(5, state: "To be merged"), row(6), row(7), row(8)], {"#{REPO}#6" => {}}, 3)
check("waiting on your review, in the queue's order", picked.map { |r| r[:number] }, [2, 7, 8])

puts "-- preparing a morning --"
$queue[:rows] = [row(10), row(11, draft: true), row(12), row(13), row(14)]
note = Prereview.run_for("furkansahin", 3)
jobs = DB.rows("SELECT pr_number, state, kind, prepared FROM review_jobs ORDER BY id")
check("three reviews queued", jobs.map { |j| j["pr_number"].to_i }, [10, 12, 13])
check("as reviews, marked prepared", jobs.map { |j| [j["state"], j["kind"], j["prepared"]] }.uniq, [["queued", "review", true]])
check("read with the box's read token", $tokens.last, "github_pat_READ")
check("and it says so", note, "prepared #10, #12, #13")
note = Prereview.run_for("furkansahin", 3)
check("the next morning skips what is already reviewed", note, "prepared #14")
$queue[:rows] = [row(10)]
check("nothing new: says so", Prereview.run_for("furkansahin", 3), "nothing to prepare: no pull request was waiting on your review")

$queue[:login] = "someone-else"
check("a read token of someone else's is refused", Prereview.run_for("furkansahin", 3).include?("belongs to someone-else"), true)
$queue[:login] = "furkansahin"
$queue[:error] = "GitHub 401: Bad credentials"
check("a dead token is said in words", Prereview.run_for("furkansahin", 3), "not prepared: could not read your queue: GitHub 401: Bad credentials")
$queue[:error] = nil
DB.exec("UPDATE bayboxes SET github_token_enc = NULL")
check("no read token: says where to add one", Prereview.run_for("furkansahin", 3), "not prepared: add a GitHub read token on the Baybox page")
check("someone no longer allowed is not prepared for", Prereview.run_for("stranger", 3).include?("no longer allowed"), true)
check("no baybox: says so", Prereview.run_for("mohi-kalantari", 3), "not prepared: no baybox registered")

puts "-- what you snoozed stays out --"
DB.exec("UPDATE bayboxes SET github_token_enc = $1", [Crypto.encrypt("github_pat_READ")])
DB.exec("DELETE FROM review_jobs")
SnoozeStore.save("furkansahin", Snooze.new({}).add("#{REPO}#30", 7 * 86_400, now: Time.now - 3600).to_h)
$queue[:rows] = [row(30), row(31)]
check("a snoozed pull request is left out, and the note says so", Prereview.run_for("furkansahin", 3), "prepared #31; left out 1 snoozed")
DB.exec("DELETE FROM review_jobs")
$queue[:rows] = [row(30, last_at: Time.now)]
check("unless it has moved since, which wakes it", Prereview.run_for("furkansahin", 3), "prepared #30")
check("the morning does not change the list itself", SnoozeStore.load("furkansahin").keys, ["#{REPO}#30"])
DB.exec("DELETE FROM review_jobs")
$queue[:rows] = [row(30)]
check("only snoozed ones waiting: says that", Prereview.run_for("furkansahin", 3),
      "nothing to prepare: no pull request was waiting on your review that you had not snoozed")
SnoozeStore.save("furkansahin", {"#{REPO}#30" => "garbage", "x" => [1]})
check("a list that is not one is read as empty", SnoozeStore.load("furkansahin"), {})
SnoozeStore.save("furkansahin", {})

puts "-- a tick writes down what happened --"
DB.exec("UPDATE bayboxes SET github_token_enc = $1", [Crypto.encrypt("github_pat_READ")])
DB.exec("DELETE FROM review_jobs")
on("furkansahin")
$queue[:rows] = [row(20)]
Prereview.tick(Time.parse("2026-10-12T05:10:00Z"))
check("the review is queued", DB.rows("SELECT pr_number FROM review_jobs").map { |j| j["pr_number"].to_i }, [20])
check("and the note says when and what", Prereview.settings("furkansahin")["prereview_note"], "2026-10-12 05:10 UTC: prepared #20")

puts "-- the setting --"
check("an hour too early", Prereview.save("furkansahin", on: true, hour: 3, count: 3, tz: "Europe/Amsterdam"), "pick an hour between 5 and 11")
check("too many", Prereview.save("furkansahin", on: true, hour: 7, count: 9, tz: "Europe/Amsterdam"), "pick between 1 and 5 reviews")
check("a time zone that is not one", Prereview.save("furkansahin", on: true, hour: 7, count: 3, tz: "Mars/Olympus"),
      "Mars/Olympus is not a time zone this server knows")

include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/baybox"
page = last_response.body
check("the Baybox page has it", page.include?("Prepare reviews"), true)
check("showing what the last morning did", page.include?("last morning: 2026-10-12 05:10 UTC: prepared #20"), true)
tok = page[%r{action="/baybox/prereview"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1]
post "/baybox/prereview", {"hour" => "8", "count" => "2", "tz" => "Europe/Istanbul", "_csrf" => tok}
s = Prereview.settings("furkansahin")
check("saving it, unticked, turns it off", [s["prereview_on"], s["prereview_hour"], s["prereview_count"], s["prereview_tz"]],
      [false, 8, 2, "Europe/Istanbul"])
post "/baybox/prereview", {"on" => "1", "hour" => "7", "count" => "3", "tz" => "Europe/Amsterdam", "_csrf" => tok}
check("ticked, on", Prereview.settings("furkansahin")["prereview_on"], true)
post "/baybox/prereview", {"on" => "1", "hour" => "7", "count" => "3", "tz" => "nowhere"}
check("not without its token", last_response.status, 403)
get "/sessions"
check("a prepared review says so in Sessions", last_response.body.include?(">prepared</span>"), true)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
