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
require "json"
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
# One stub for the dev box. Mutable, so a test can change how a verb behaves.
STUB = {teardown: {ok: true, output: "torn down"}, asked: nil}
DevBox.singleton_class.prepend(Module.new do
  def run(_box, command, timeout: 30, stdin: nil)
    case command
    when "list" then {ok: true, output: "rq-ubicloud-6172\tdeepak/x\tUp 2 minutes\n"}
    when /\Ateardown / then STUB[:teardown]
    when /\Aask / then STUB[:asked] = stdin; {ok: true, output: "asked"}
    else {ok: true, output: "started"}
    end
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

# progress on a running job must show, and must not change its state
job_id = DB.row("SELECT id FROM review_jobs ORDER BY id DESC LIMIT 1")["id"]
DB.exec("UPDATE review_jobs SET state='running' WHERE id=$1", [job_id])
Jobs.progress(job_id, "## Review summary\nfinding one", "reviewing")
check("progress is stored", DB.row("SELECT output FROM review_jobs WHERE id=$1", [job_id])["output"].include?("finding one"), true)
check("phase is stored", DB.row("SELECT phase FROM review_jobs WHERE id=$1", [job_id])["phase"], "reviewing")
check("progress does not change state", DB.row("SELECT state FROM review_jobs WHERE id=$1", [job_id])["state"], "running")
get "/sessions"
check("claude output panel is shown while running", last_response.body.include?("claude output"), true)
check("the partial text is shown", last_response.body.include?("finding one"), true)

# the tail endpoint returns only what is new
t = JSON.parse(get("/sessions/tail?id=#{job_id}&offset=0").body)
check("tail returns the whole text at offset 0", t["chunk"].include?("finding one"), true)
check("tail reports the phase", t["phase"], "reviewing")
check("tail says not done", t["done"], false)
t2 = JSON.parse(get("/sessions/tail?id=#{job_id}&offset=#{t["length"]}").body)
check("tail returns nothing new at the end", t2["chunk"], "")
Jobs.progress(job_id, "## Review summary\nfinding one\nfinding two", "reviewing")
t3 = JSON.parse(get("/sessions/tail?id=#{job_id}&offset=#{t["length"]}").body)
check("tail returns only the appended part", t3["chunk"].strip, "finding two")
# another user must not be able to read my job through it
WHO[:login] = "mohi-kalantari"
oo = Rack::Test::Session.new(Rack::MockSession.new(app))
oo.get "/auth/start"; s3 = oo.last_response.location[/state=([^&]+)/, 1]
oo.get "/auth/callback?code=c&state=#{s3}"
oo.get "/sessions/tail?id=#{job_id}&offset=0"
check("tail is scoped to the owner", oo.last_response.body.include?("finding one"), false)
WHO[:login] = "furkansahin"
# and it must refuse to touch a job that already finished
DB.exec("UPDATE review_jobs SET state='done' WHERE id=$1", [job_id])
Jobs.progress(job_id, "LATE WRITE")
check("progress cannot overwrite a finished job",
      DB.row("SELECT output FROM review_jobs WHERE id=$1", [job_id])["output"].include?("LATE WRITE"), false)
DB.exec("UPDATE review_jobs SET state='running' WHERE id=$1", [job_id])

# finish it and check it moves to Previous with its output
DB.exec("UPDATE review_jobs SET state='done', output=$1, finished_at=now()", ["FINDING: something"])
get "/sessions"
check("finished job shows its output", last_response.body.include?("FINDING: something"), true)

# a job from the old single-stream wrapper must not bury the review
mixed = (["docker build noise"] * 500).join("\n") + "\n== review\n## Review summary\nthe actual finding"
DB.exec("UPDATE review_jobs SET output=$1 WHERE state='done'", [mixed])
get "/sessions"
b = last_response.body
check("old mixed log: review is split out", b.include?("claude&#39;s review") || b.include?("claude's review"), true)
check("old mixed log: build noise is behind its own toggle", b.include?("not the review"), true)
check("old mixed log: the finding is present", b.include?("the actual finding"), true)
check("old mixed log: noise is truncated", b.scan("docker build noise").size <= 200, true)

# panels must be keyed so their open/closed state can survive a refresh
get "/sessions"
check("review panel is keyed", last_response.body.include?('data-keep="review-'), true)
check("no forced reload on completion", last_response.body.include?("location.reload"), false)
# the live panel only exists while a job is running
DB.exec("UPDATE review_jobs SET state='running' WHERE id=$1", [job_id])
get "/sessions"
check("live panel is keyed", last_response.body.include?(%(data-keep="live-#{job_id}")), true)
DB.exec("UPDATE review_jobs SET state='done' WHERE id=$1", [job_id])

# --- follow-up ------------------------------------------------------------
DB.exec("UPDATE review_jobs SET state='done', finished_at=now() WHERE id=$1", [job_id])
get "/sessions"
check("finished job offers a follow-up box", last_response.body.include?('name="prompt"'), true)
atok = csrf_for(last_response.body, "/sessions/ask")
post "/sessions/ask", {"id" => job_id, "prompt" => "why is finding 1 exploitable?", "_csrf" => atok}
check("the question goes over stdin, not the command line", STUB[:asked], "why is finding 1 exploitable?")
check("the job goes back to running", DB.row("SELECT state FROM review_jobs WHERE id=$1", [job_id])["state"], "running")
check("and back to the reviewing phase", DB.row("SELECT phase FROM review_jobs WHERE id=$1", [job_id])["phase"], "reviewing")

# a follow-up while it is already running must be refused
post "/sessions/ask", {"id" => job_id, "prompt" => "again", "_csrf" => atok}
get "/sessions"
check("cannot ask while it is still running", last_response.body.include?("wait for the review to finish"), true)

DB.exec("UPDATE review_jobs SET state='done', finished_at=now() WHERE id=$1", [job_id])
get "/sessions"; atok = csrf_for(last_response.body, "/sessions/ask")
post "/sessions/ask", {"id" => job_id, "prompt" => "   ", "_csrf" => atok}
get "/sessions"
check("an empty question is refused", last_response.body.include?("type a question first"), true)
post "/sessions/ask", {"id" => job_id, "prompt" => "x" * 9000, "_csrf" => atok}
get "/sessions"
check("an oversized question is refused", last_response.body.include?("8 KB limit"), true)
post "/sessions/ask", {"id" => job_id, "prompt" => "no csrf"}
check("ask without CSRF is blocked", last_response.status, 403)

# --- teardown -------------------------------------------------------------
# a teardown that works must say so, and must free the pull request
DB.exec("UPDATE review_jobs SET state='done', box_name='rq-ubicloud-6172' WHERE id=$1", [job_id])
get "/"
check("row claims reviewed before teardown", last_response.body.include?("review ✓"), true)
get "/sessions"
post "/sessions/teardown", {"box" => "rq-ubicloud-6172", "_csrf" => csrf_for(last_response.body, "/sessions/teardown")}
get "/sessions"
check("a successful teardown is confirmed", last_response.body.include?("tore down rq-ubicloud-6172"), true)
check("the job is marked torn down",
      DB.row("SELECT torn_down_at IS NOT NULL AS t FROM review_jobs WHERE id=$1", [job_id])["t"], true)
get "/"
check("row offers Review again after teardown", last_response.body.include?(">Review<"), true)
check("row no longer claims reviewed", last_response.body.include?("review ✓"), false)

# the card must leave Previous, not sit there looking untouched
get "/sessions"
body = last_response.body
prev_start = body.index("Previous")
gone_start = body.index("Torn down")
check("a Torn down section appears", !gone_start.nil?, true)
check("the card sits after Previous, not in it", (gone_start || 0) > (prev_start || 0), true)
check("it is labelled torn down", body.include?(">torn down<"), true)
# assert on the review text itself, not on template wording
kept = DB.row("SELECT output FROM review_jobs WHERE id=$1", [job_id])["output"].to_s
check("the torn-down job still has its review in the database", kept.empty?, false)
check("and the page still renders it",
      body[gone_start..].to_s.include?(kept.split("\n").last.to_s.strip), true)
check("Previous no longer offers a teardown for it",
      body[prev_start...gone_start].to_s.include?("Tear down box"), false)

# forget deletes the record outright
ft = csrf_for(body, "/sessions/forget")
post "/sessions/forget", {"id" => job_id, "_csrf" => ft}
check("forget removes the record",
      DB.row("SELECT count(*)::int n FROM review_jobs WHERE id=$1", [job_id])["n"], 0)

# and it must refuse a job whose box is still alive
j2 = DB.row(<<~SQL, ["furkansahin", "ubicloud/ubicloud", 7777, "rq-ubicloud-7777"])
  INSERT INTO review_jobs (login, repo, pr_number, box_name, state)
  VALUES ($1,$2,$3,$4,'done') RETURNING *
SQL
get "/sessions"
post "/sessions/forget", {"id" => j2["id"], "_csrf" => csrf_for(last_response.body, "/sessions/forget")}
check("forget refuses a job whose box still exists",
      DB.row("SELECT count(*)::int n FROM review_jobs WHERE id=$1", [j2["id"]])["n"], 1)
DB.exec("DELETE FROM review_jobs WHERE id=$1", [j2["id"]])

STUB[:teardown] = {ok: false, output: "", error: "box \"rq-x\" has uncommitted changes in its worktree"}
get "/sessions"
tok = csrf_for(last_response.body, "/sessions/teardown")
post "/sessions/teardown", {"box" => "rq-ubicloud-6172", "_csrf" => tok}
get "/sessions"
check("a failed teardown is reported, not silent",
      last_response.body.include?("could not tear down rq-ubicloud-6172"), true)
check("and it quotes the reason", last_response.body.include?("uncommitted changes"), true)
get "/sessions"
check("the error clears after one view", last_response.body.include?("could not tear down"), false)

# every id-taking route must survive a missing or junk id: these reached the
# database as a bigint and raised PG::InvalidTextRepresentation, i.e. a 500
get "/sessions"
tt = csrf_for(last_response.body, "/sessions/teardown")
ct = csrf_for(last_response.body, "/sessions/cancel")
at = csrf_for(last_response.body, "/sessions/ask")
[["", "empty"], ["abc", "non-numeric"], ["-1", "negative"], ["99999999999999999999", "huge"]].each do |bad, label|
  post "/sessions/teardown", {"id" => bad, "_csrf" => tt}
  check("teardown survives an #{label} id", last_response.status < 500, true)
  post "/sessions/cancel", {"id" => bad, "_csrf" => ct}
  check("cancel survives an #{label} id", last_response.status < 500, true)
  post "/sessions/ask", {"id" => bad, "prompt" => "hi", "_csrf" => at}
  check("ask survives an #{label} id", last_response.status < 500, true)
  get "/sessions/tail?id=#{bad}&offset=0"
  check("tail survives an #{label} id", last_response.status < 500, true)
end
post "/sessions/teardown", {"_csrf" => tt}
check("teardown survives no id at all", last_response.status < 500, true)

# a box name that is not ours must be refused before it is sent anywhere
post "/sessions/teardown", {"box" => "../etc/passwd", "_csrf" => tok}
get "/sessions"
check("a bad box name is refused", last_response.body.include?("bad box name"), true)

# boxes with no job row still get a teardown control
get "/sessions"
check("boxes section offers teardown", last_response.body.scan(">Tear down<").size >= 1, true)

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
