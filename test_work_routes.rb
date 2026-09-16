#!/usr/bin/env ruby
# Issues tab, work sessions and publishing, through the app:
#   DATABASE_URL=... bundle exec ruby test_work_routes.rb
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_SCOPE"]                = "repo:ubicloud/ubicloud"
require "rack/test"
require_relative "app"
require_relative "runner"
require_relative "worker"

ME = "furkansahin"
REPO = "ubicloud/ubicloud"
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => ME} } }

# Real rows, from the real code, so the page is tested against what it will
# actually be handed.
def gql_issue(n, linked: [])
  {"number" => n, "title" => "Issue #{n}", "url" => "https://github.com/#{REPO}/issues/#{n}",
   "updatedAt" => (Time.now - 3600).utc.iso8601, "author" => {"login" => "reporter"},
   "repository" => {"nameWithOwner" => REPO}, "labels" => {"nodes" => []},
   "closedByPullRequestsReferences" => {"nodes" => linked}, "timelineItems" => {"nodes" => []}}
end
ISSUES = {rows: QueueService.new(token: "x", scope: "repo:#{REPO}", label: "").send(:issue_rows, [
  gql_issue(6458),
  gql_issue(6459, linked: [{"number" => 6470, "title" => "Handle the thing", "url" => "https://github.com/#{REPO}/pull/6470",
                            "state" => "OPEN", "isDraft" => false, "author" => {"login" => "enescakir"}}])
], ME), error: nil}
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: ME, fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: ISSUES[:rows], issues_error: ISSUES[:error]}
  end
end

# The machine, answered from here, with every command recorded.
$commands = []
$answers = {}
runner_stub = Module.new do
  def run(_box, cmd, timeout: 30, stdin: nil)
    $commands << cmd
    verb = cmd.split(" ").first
    $answers.fetch(verb, {ok: true, output: ""})
  end
  def box_list(_box_row) = []
  def forget_box_list(_box_row) = nil
end
Runner.singleton_class.prepend(runner_stub)

include Rack::Test::Methods
def app = ReviewQueue.app
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")

puts "-- schema --"
cols = DB.rows("SELECT table_name, column_name, column_default FROM information_schema.columns " \
               "WHERE table_name IN ('review_jobs', 'bayboxes')").map { |c| ["#{c["table_name"]}.#{c["column_name"]}", c["column_default"]] }.to_h
check("jobs have a kind", cols.key?("review_jobs.kind"), true)
check("which defaults to review, so old rows stay reviews", cols["review_jobs.kind"].to_s.include?("review"), true)
check("a branch, a summary and a pull request",
      %w[branch summary pr_url].all? { |c| cols.key?("review_jobs.#{c}") }, true)
check("bayboxes have a separate write token", cols.key?("bayboxes.github_write_token_enc"), true)

get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

puts "-- the write token is stored like the others --"
get "/baybox"
check("the page offers a write token field", last_response.body.include?('name="github_write_token"'), true)
check("and says which permissions", last_response.body.include?("Pull requests: Read and write"), true)
check("and to leave Workflows off", last_response.body.include?("Workflows"), true)
tok = csrf_for(last_response.body, "/baybox/save")
post "/baybox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22",
                      "github_token" => "github_pat_READ", "github_write_token" => "github_pat_WRITE", "_csrf" => tok}
box = DB.row("SELECT * FROM bayboxes WHERE login = $1", [ME])
check("it is saved", Crypto.decrypt(box["github_write_token_enc"]), "github_pat_WRITE")
check("encrypted at rest", box["github_write_token_enc"].include?("github_pat_WRITE"), false)
check("apart from the read token", Crypto.decrypt(box["github_token_enc"]), "github_pat_READ")
get "/baybox"
check("the page never shows it back", last_response.body.include?("github_pat_WRITE"), false)
check("it says one is stored", last_response.body.include?("stored — leave blank to keep it, or - to remove it"), true)
tok = csrf_for(last_response.body, "/baybox/save")
post "/baybox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22", "github_write_token" => "", "_csrf" => tok}
check("blank keeps it", Crypto.decrypt(DB.row("SELECT * FROM bayboxes WHERE login = $1", [ME])["github_write_token_enc"]), "github_pat_WRITE")
# That the box's env file never gets the write token is held in test_work.rb,
# which has a real bay root to write it into.

puts "-- the issues tab --"
get "/?tab=issues"
body = last_response.body
check("renders", last_response.status, 200)
check("lists the issue", body.include?("Issue 6458"), true)
check("with its pull request", body.include?("#6470 Handle the thing"), true)
check("and its state", body.include?("PR open"), true)
check("offers to work on it", body.include?("Work on it"), true)
check("posting to /work", body.include?('action="/work?tab=issues"'), true)
check("the badge counts what is still to do", body[%r{My issues</span>\s*<span class="badge">([^<]+)}, 1], "1/2")
check("no Next up hero here", body.include?("Next up"), false)
check("no review button here", body.include?(">Review</button>"), false)

ISSUES[:error] = "GitHub GraphQL: broke"
get "/?tab=issues"
check("a failure is shown", last_response.body.include?("Could not read your issues: GitHub GraphQL: broke"), true)
check("and not as an empty list", last_response.body.include?("No open issues are assigned"), false)
ISSUES[:error] = nil

puts "-- starting work --"
get "/?tab=issues"
tok = csrf_for(last_response.body, "/work")
post "/work?tab=issues", {"repo" => REPO, "issue" => "6458", "_csrf" => tok}
check("redirects back to the tab", last_response.location.to_s.include?("tab=issues"), true)
job = DB.row("SELECT * FROM review_jobs WHERE login = $1", [ME])
check("a job is queued", job && job["state"], "queued")
check("as work", job["kind"], "work")
check("on the issue's own box", job["box_name"], "rq-ubicloud-ubicloud-issue-6458")
check("a review of the same number is not confused with it", Jobs.by_key(ME).key?("#{REPO}#6458"), false)
check("the work lookup finds it", Jobs.by_key(ME, "work")["#{REPO}#6458"]["state"], "queued")

post "/work?tab=issues", {"repo" => REPO, "issue" => "6458", "_csrf" => tok}
follow_redirect!
check("a second press is refused", last_response.body.include?("work on this issue is already running"), true)
check("and says it could not start the work", last_response.body.include?("Could not start the work"), true)
post "/work?tab=issues", {"repo" => REPO, "issue" => "abc", "_csrf" => tok}
follow_redirect!
check("a bad number is refused", last_response.body.include?("that issue number is not valid"), true)

puts "-- the worker starts it as work --"
$commands.clear
$answers["work"] = {ok: true, output: "started", branch: "issue-6458-issue"}
start_queued
check("it runs the work verb", $commands.first, "work #{REPO} 6458 rq-ubicloud-ubicloud-issue-6458")
job = DB.row("SELECT * FROM review_jobs WHERE id = $1", [job["id"]])
check("it is running", job["state"], "running")
check("the branch is recorded", job["branch"], "issue-6458-issue")
get "/?tab=issues"
check("the row says it is working", last_response.body.include?("working…"), true)

puts "-- and records what the branch holds when it stops --"
summary = {head: "issue-6458-issue", ahead: 2, dirty: 0, stat: "3 files changed, 40 insertions(+)",
           files: ["lib/thing.rb", ".github/workflows/ci.yml"], commits: ["abc123 Reset it"],
           title: "Reset deadline_start", body: "Fixes #6458", touches_ci: true, rq_files: []}
$commands.clear
$answers["status"] = {ok: true, output: "done"}
$answers["result"] = {ok: true, output: "I changed two files."}
$answers["inspect"] = {ok: true, output: JSON.generate(summary), summary: summary}
poll_running
job = DB.row("SELECT * FROM review_jobs WHERE id = $1", [job["id"]])
check("it is done", job["state"], "done")
check("it inspected the branch", $commands.include?("inspect rq-ubicloud-ubicloud-issue-6458"), true)
check("and stored the summary", JSON.parse(job["summary"].to_s)["ahead"], 2)

puts "-- the session card --"
get "/sessions"
body = last_response.body
check("marks it as an issue", body.include?('class="kind"'), true)
check("links to the issue, not a pull request", body.include?("https://github.com/#{REPO}/issues/6458"), true)
check("shows the branch", body.include?("issue-6458-issue"), true)
check("and the commits", body.include?("2 commits"), true)
check("warns that it changes CI", body.include?("changes .github/"), true)
check("offers to open a draft pull request", body.include?("Open draft PR"), true)
check("asks for changes, not follow-up questions", body.include?("Ask for a change in this box"), true)
check("the placeholder is not double-escaped", body.include?("&amp;quot;"), false)

DB.exec("UPDATE bayboxes SET github_write_token_enc = NULL WHERE login = $1", [ME])
get "/sessions"
check("without a write token it says what is missing", last_response.body.include?("add a write token to open a PR"), true)
check("and offers no button", last_response.body.include?("Open draft PR"), false)
DB.exec("UPDATE bayboxes SET github_write_token_enc = $1 WHERE login = $2", [Crypto.encrypt("github_pat_WRITE"), ME])

puts "-- publishing --"
review = DB.row(<<~SQL, [ME, box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind)
  VALUES ($1, $2, $3, 6470, 'rq-ubicloud-ubicloud-6470', 'done', 'review') RETURNING *
SQL
get "/sessions"
tok = csrf_for(last_response.body, "/sessions/publish")
check("a review card links to the pull request", last_response.body.include?("https://github.com/#{REPO}/pull/6470"), true)

$commands.clear
post "/sessions/publish", {"id" => review["id"].to_s, "_csrf" => tok}
follow_redirect!
check("a review cannot open a pull request", last_response.body.include?("only work on an issue"), true)
check("and nothing was run", $commands, [])

$answers["publish"] = {ok: false, error: "not opening a pull request: 1 uncommitted change in the box", summary: summary}
post "/sessions/publish", {"id" => job["id"].to_s, "_csrf" => tok}
follow_redirect!
check("a refusal is shown", last_response.body.include?("1 uncommitted change"), true)
check("and no pull request is recorded", DB.row("SELECT pr_url FROM review_jobs WHERE id = $1", [job["id"]])["pr_url"], nil)

$commands.clear
$answers["publish"] = {ok: true, pr_url: "https://github.com/#{REPO}/pull/6500", updated: false, summary: summary}
post "/sessions/publish", {"id" => job["id"].to_s, "_csrf" => tok}
check("it asks the machine to publish that branch",
      $commands, ["publish #{REPO} 6458 rq-ubicloud-ubicloud-issue-6458 issue-6458-issue"])
follow_redirect!
check("says where the pull request is", last_response.body.include?("opened a draft pull request: https://github.com/#{REPO}/pull/6500"), true)
check("records it", DB.row("SELECT pr_url FROM review_jobs WHERE id = $1", [job["id"]])["pr_url"],
      "https://github.com/#{REPO}/pull/6500")
check("the card now pushes changes instead", last_response.body.include?("Push changes"), true)
get "/?tab=issues"
check("and the issue row links to it", last_response.body.include?("your PR ↗"), true)

DB.exec("UPDATE review_jobs SET state = 'running' WHERE id = $1", [job["id"]])
$commands.clear
post "/sessions/publish", {"id" => job["id"].to_s, "_csrf" => tok}
follow_redirect!
check("nothing is pushed while it is still working", $commands, [])
check("and it says to wait", last_response.body.include?("wait for the work to finish"), true)

puts "-- someone else's session --"
other = DB.row(<<~SQL, [box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, branch)
  VALUES ('mohi-kalantari', $1, $2, 6461, 'rq-ubicloud-ubicloud-issue-6461', 'done', 'work', 'issue-6461') RETURNING *
SQL
$commands.clear
post "/sessions/publish", {"id" => other["id"].to_s, "_csrf" => tok}
check("cannot be published by id", $commands, [])

puts "-- a review job still starts as a review --"
DB.exec("DELETE FROM review_jobs")
Jobs.enqueue(login: ME, repo: REPO, pr_number: 6470)
$commands.clear
$answers["review"] = {ok: true, output: "started"}
start_queued
check("the worker runs review", $commands.first, "review #{REPO} 6470 rq-ubicloud-ubicloud-6470")

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
