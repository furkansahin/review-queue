#!/usr/bin/env ruby
# Sessions/review route tests:  DATABASE_URL=... bundle exec ruby test_sessions_routes.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]         = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]         = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]       = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"]   = "csecret"
ENV["RQ_BASE_URL"]               = "http://example.com"
ENV["RQ_SESSION_SECRET"]         = "a" * 64
ENV["RQ_INSECURE_COOKIES"]       = "1"

require "rack/test"
require_relative "app"
require_relative "devbox"

WHO = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WHO[:login]} } }

def mkrow(repo, n)
  {key: "#{repo}##{n}", repo: repo.split("/").last, repo_full: repo, number: n, last_at: Time.now - 86_400, settled: false,
   buckets: [:review], quick: false, draft: false, url: "https://github.com/#{repo}/pull/#{n}",
   title: "PR #{n}", ref: "#{repo} ##{n}", author: "someone", state: "To review",
   state_bg: "var(--state-todo-bg)", state_color: "var(--state-todo-fg)", chips: [],
   row_bg: "var(--row)", age_color: "var(--age-stale-bar)", age_text_color: "var(--age-stale-fg)",
   age: "3d", read_est: "~2m", size_sub: "±20 · 2f", last_activity: "3d ago", last_actor: "someone",
   my_action: "never", my_action_kind: "no activity from you", ci: "pass", ci_color: "var(--ci-pass)"}
end
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    rows = [mkrow("ubicloud/ubicloud", 6172)]
    {rows: rows, counts: counts(rows), login: WHO[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: {count: 0, complete: true}}
  end
end
# the dev box is unreachable in tests; that must degrade, not crash
DevBox.singleton_class.prepend(Module.new do
  def run(_box, command, timeout: 30)
    return {ok: true, output: "rq-ubicloud-6172\tdeepak/x\tUp 2 minutes\n"} if command == "list"
    {ok: true, output: "started"}
  end
end)

include Rack::Test::Methods
def app = ReviewQueue.app
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,24], want.inspect[0,24])
end
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
priv, pub = DevBox.generate_keypair
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "10.0.0.5", Crypto.encrypt(priv), pub])

get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

# with no dev box the button must not silently do nothing
DB.exec("DELETE FROM dev_boxes WHERE login = $1", ["furkansahin"])
get "/"
check("no dev box -> offers Set up, not Review", last_response.body.include?(">Set up</a>"), true)
tok0 = csrf_for(last_response.body, "/review") rescue tok0 = nil
check("no dev box -> no review form at all", tok0.nil?, true)
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "203.0.113.10", Crypto.encrypt(priv), pub])

get "/"
check("Review button is offered", last_response.body.include?(">Review<"), true)
# the form must post owner/name, not the bare repo name: a bare name fails
# DevBox validation with "bad repo"
check("form posts the full owner/name",
      last_response.body.include?('name="repo" value="ubicloud/ubicloud"'), true)
check("Sessions link is in the bar", last_response.body.include?('href="/sessions"'), true)

tok = csrf_for(last_response.body, "/review")
post "/review", {"repo" => "ubicloud/ubicloud", "pr" => "6172", "_csrf" => tok}
check("review enqueues and redirects", last_response.status, 302)
check("a job row exists", DB.row("SELECT state FROM review_jobs")["state"], "queued")

get "/"
check("row now shows the job state", last_response.body.include?(">queued</a>"), true)

# a second press must not start a second box
post "/review", {"repo" => "ubicloud/ubicloud", "pr" => "6172", "_csrf" => tok}
check("double press makes only one job", DB.row("SELECT count(*)::int n FROM review_jobs")["n"], 1)

post "/review", {"repo" => "ubicloud/ubicloud", "pr" => "6172"}
check("review without CSRF is blocked", last_response.status, 403)

# a rejected enqueue must tell the user why
DB.exec("TRUNCATE review_jobs RESTART IDENTITY CASCADE")
DB.exec("DELETE FROM dev_boxes WHERE login = $1", ["furkansahin"])
get "/"
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "203.0.113.10", Crypto.encrypt(priv), pub])
get "/"; t2 = csrf_for(last_response.body, "/review")
DB.exec("DELETE FROM dev_boxes WHERE login = $1", ["furkansahin"])
post "/review", {"repo" => "ubicloud/ubicloud", "pr" => "6172", "_csrf" => t2}
get "/"
check("failed review shows an explanation", last_response.body.include?("Could not start the review"), true)
check("and points at the dev box page", last_response.body.include?("register one"), true)
get "/"
check("the banner is shown once, then cleared", last_response.body.include?("Could not start the review"), false)

# put the state back for the sessions assertions below
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "203.0.113.10", Crypto.encrypt(priv), pub])
get "/"; post "/review", {"repo" => "ubicloud/ubicloud", "pr" => "6172",
                          "_csrf" => csrf_for(last_response.body, "/review")}

get "/sessions"
check("sessions page renders", last_response.status, 200)
check("active section lists the job", last_response.body.include?("ubicloud/ubicloud #6172"), true)
check("links to the pull request", last_response.body.include?("https://github.com/ubicloud/ubicloud/pull/6172"), true)
check("shows real boxes from the dev box", last_response.body.include?("rq-ubicloud-6172"), true)

# finish it and check it moves to Previous with its output
DB.exec("UPDATE review_jobs SET state='done', output=$1, finished_at=now()", ["FINDING: something"])
get "/sessions"
check("finished job shows its output", last_response.body.include?("FINDING: something"), true)

# another user must not see it
WHO[:login] = "mohi-kalantari"
other = Rack::Test::Session.new(Rack::MockSession.new(app))
other.get "/auth/start"; st2 = other.last_response.location[/state=([^&]+)/, 1]
other.get "/auth/callback?code=c&state=#{st2}"
other.get "/sessions"
check("another user sees no sessions of mine", other.last_response.body.include?("FINDING: something"), false)
check("another user gets their own empty page", other.last_response.status, 200)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
