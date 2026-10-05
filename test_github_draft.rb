#!/usr/bin/env ruby
# A box's review as a pending review on GitHub:  bundle exec ruby test_github_draft.rb
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
require_relative "runner"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

REPO = "ubicloud/ubicloud"
HEAD = "c0" * 20
BASE = "ba" * 20
PATCH = "@@ -10,4 +10,5 @@ class Nexus\n   def start\n-    old_call\n+    new_call\n+    other_call\n   end\n"

$routes = {}
$calls = []
def answer(token, verb, path, body = nil)
  $calls << [token, verb, path, body]
  v = $routes.fetch([verb, path]) { raise %(GitHub 404 on #{path}: {"message":"Not Found"}) }
  raise v if v.is_a?(String)
  v
end
class FakeGH
  def initialize(token = "t") = (@token = token)
  def get(path) = answer(@token, :get, path)
  def post(path, body) = answer(@token, :post, path, body)
end
def github(head: HEAD, state: "open", reviews: [])
  $calls.clear
  $routes = {
    [:get, "/repos/#{REPO}/pulls/6503"] => {"state" => state, "merged_at" => nil, "title" => "Postgres backup lag",
                                            "html_url" => "https://github.com/#{REPO}/pull/6503",
                                            "head" => {"sha" => head}, "base" => {"sha" => BASE}},
    [:get, "/repos/#{REPO}/pulls/6503/reviews?per_page=100"] => reviews,
    [:get, "/repos/#{REPO}/compare/#{BASE}...#{HEAD}"] => {"files" => [
      {"filename" => "prog/nexus.rb", "status" => "modified", "patch" => PATCH},
      {"filename" => "new/name.rb", "previous_filename" => "old/name.rb", "status" => "renamed",
       "patch" => "@@ -1,2 +1,2 @@\n-a = 1\n+a = 2\n b\n"},
      {"filename" => "logo.png", "status" => "modified"}]},
    [:post, "/repos/#{REPO}/pulls/6503/reviews"] => {"id" => 77, "state" => "PENDING",
                                                     "html_url" => "https://github.com/#{REPO}/pull/6503#pullrequestreview-77"}
  }
end
def writes = $calls.reject { |c| c[1] == :get }
def json(comments, summary: "One real problem.") = JSON.generate({summary: summary, comments: comments})
C_ADD = {path: "prog/nexus.rb", line: 11, side: "RIGHT", body: "new_call can raise. verified — rspec: 1 failure"}
C_DEL = {path: "prog/nexus.rb", line: 11, side: "LEFT", body: "old_call handled the nil case. read-only"}
C_FAR = {path: "prog/nexus.rb", line: 300, side: "RIGHT", body: "Unrelated: this loop never ends.\nSecond line."}

puts "-- reading the box's file --"
ok = GitHubDraft.parse(json([C_ADD, C_DEL]))
check("two comments", ok[:comments].size, 2)
check("as GitHub takes them", ok[:comments].first, C_ADD)
check("side defaults to the new code", GitHubDraft.parse(json([C_ADD.merge(side: nil)]))[:comments].first[:side], "RIGHT")
check("a line as a string still counts", GitHubDraft.parse(json([C_ADD.merge(line: "11")]))[:comments].first[:line], 11)
check("not JSON", GitHubDraft.parse("{oops")[:error].to_s.include?("not valid JSON"), true)
check("a path out of the repository", GitHubDraft.parse(json([C_ADD.merge(path: "../etc/passwd")]))[:error].to_s.include?("no usable file"), true)
check("no line", GitHubDraft.parse(json([C_ADD.merge(line: 0)]))[:error].to_s.include?("no line"), true)
check("an empty comment", GitHubDraft.parse(json([C_ADD.merge(body: " ")]))[:error].to_s.include?("says nothing"), true)
check("too many", GitHubDraft.parse(json([C_ADD] * 101))[:error].to_s.include?("more than 100"), true)

puts "-- where they go --"
github
plan = GitHubDraft.plan(FakeGH.new, REPO, 6503, commit: HEAD, findings: GitHubDraft.parse(json([C_ADD, C_DEL, C_FAR])), login: "furkansahin")
check("an added line takes a comment", plan[:placed].include?(C_ADD), true)
check("so does a removed one, on its old side", plan[:placed].include?(C_DEL), true)
check("a line the diff does not show goes to the summary", plan[:loose], [C_FAR])
check("against the reviewed commit", [plan[:commit], plan[:moved]], [HEAD, false])
files = GitHubDraft.diff_files(FakeGH.new, REPO, BASE, HEAD)
check("a renamed file by its new name", GitHubDraft.placeable?(files, {path: "new/name.rb", line: 1, side: "RIGHT"}), true)
check("and its old one, on the old side", GitHubDraft.placeable?(files, {path: "old/name.rb", line: 1, side: "LEFT"}), true)
check("a binary file takes none", GitHubDraft.placeable?(files, {path: "logo.png", line: 1, side: "RIGHT"}), false)
github(head: "d1" * 20)
check("a pull request that moved on says so",
      GitHubDraft.plan(FakeGH.new, REPO, 6503, commit: HEAD, findings: GitHubDraft.parse(json([C_ADD])), login: "furkansahin")[:moved], true)
github(state: "closed")
check("a closed one is refused", GitHubDraft.plan(FakeGH.new, REPO, 6503, commit: HEAD, findings: GitHubDraft.parse(json([])), login: "x")[:error], "#6503 is closed")

puts "-- drafting it --"
github
res = GitHubDraft.create(FakeGH.new, plan)
sent = writes.first[3]
check("one write: the review", writes.map { |c| [c[1], c[2]] }, [[:post, "/repos/#{REPO}/pulls/6503/reviews"]])
check("left pending: no event", sent.key?(:event), false)
check("on the reviewed commit", sent[:commit_id], HEAD)
check("with the line comments", sent[:comments], [C_ADD, C_DEL])
check("the summary first", sent[:body].start_with?("One real problem."), true)
check("the rest after it, by file and line", sent[:body].include?("- `prog/nexus.rb` line 300: Unrelated: this loop never ends. Second line."), true)
check("and where it came from", sent[:body].end_with?(GitHubDraft::FOOTER), true)
check("answering with the review", [res[:ok], res[:url], res[:comments]], [true, "https://github.com/#{REPO}/pull/6503#pullrequestreview-77", 2])
kept = GitHubDraft.keep(plan, ["1", "2", "nonsense", "99"])
check("keep counts lines first, then the summary's", [kept[:placed], kept[:loose], kept[:dropped]], [[C_DEL], [C_FAR], 1])
check("nothing kept and no summary: nothing drafted",
      GitHubDraft.create(FakeGH.new, GitHubDraft.keep(plan.merge(summary: ""), []))[:error].to_s.include?("nothing to draft"), true)
github(reviews: [{"id" => 9, "state" => "PENDING", "user" => {"login" => "FurkanSahin"}, "html_url" => "https://github.com/x#r9"}])
pend = GitHubDraft.plan(FakeGH.new, REPO, 6503, commit: HEAD, findings: GitHubDraft.parse(json([C_ADD])), login: "furkansahin")
check("a pending review of yours is found", pend[:pending], "https://github.com/x#r9")
check("and nothing is drafted over it", [GitHubDraft.create(FakeGH.new, pend)[:error].to_s.include?("already have a pending"), writes], [true, []])
github
$routes[[:post, "/repos/#{REPO}/pulls/6503/reviews"]] = %(GitHub 403 on /x: {"message":"Resource not accessible by personal access token"})
check("a token that cannot says what it needs", GitHubDraft.create(FakeGH.new, plan)[:error].to_s.include?("Pull requests: Read and write"), true)

puts "-- through the app --"
include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
GitHubClient.class_eval do
  define_method(:get) { |path| path == "/user" ? {"login" => "furkansahin"} : answer(@token, :get, path) }
  define_method(:post) { |path, body| answer(@token, :post, path, body) }
end
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: "furkansahin", fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: []}
  end
end
$box = {ok: true, head: HEAD, json: json([C_ADD, C_FAR])}
$asked = []
Runner.singleton_class.prepend(Module.new do
  def run(_box, cmd, timeout: 30, stdin: nil)
    return $box if cmd.start_with?("findings ")
    ($asked << stdin; return {ok: true, output: "started"}) if cmd.start_with?("ask ")
    {ok: true, output: ""}
  end
  def box_list(_) = []
  def forget_box_list(_) = nil
end)
DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
box = DB.row(<<~SQL, ["furkansahin", Crypto.encrypt("github_pat_WRITE")])
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key, github_write_token_enc)
  VALUES ($1, '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA', $2) RETURNING *
SQL
job = DB.row(<<~SQL, [box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, finished_at)
  VALUES ('furkansahin', $1, $2, 6503, 'rq-ubicloud-ubicloud-6503', 'done', 'review', now()) RETURNING *
SQL
other = DB.row(<<~SQL, [box["id"], REPO])["id"]
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, finished_at)
  VALUES ('mohi-kalantari', $1, $2, 6504, 'rq-x-6504', 'done', 'review', now()) RETURNING id
SQL
form = ->(body, path) { body[%r{action="#{Regexp.escape(path)}[?"][^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1] }

get "/sessions"
check("a finished review's card offers it", last_response.body.include?(%(href="/sessions/draft?id=#{job["id"]}")), true)
github
get "/sessions/draft?id=#{job["id"]}"
page = last_response.body
check("the page shows the comment on its line", page.include?("prog/nexus.rb · line 11") && page.include?("new_call can raise"), true)
check("and the one going to the summary", page.include?("1 in the summary"), true)
check("read with the session's token", $calls.map(&:first).uniq, ["gho_session"])
check("writing nothing", writes, [])
get "/sessions/draft?id=#{other}"
check("someone else's review is not shown", last_response.status, 302)

token = form.(page, "/sessions/draft")
digest = page[/name="digest" value="(\h{64})"/, 1]
check("every comment has a box, ticked", page.scan(/name="keep\[\]" value="(\d+)" checked="checked"/).flatten, %w[0 1])
check("counted by the button", page.include?("2 of 2 kept"), true)
post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "keep" => %w[0 1]}
check("without its token it is refused", last_response.status, 403)

# Same number of findings, one reworded: the ticks would land on other words.
$box = {ok: true, head: HEAD, json: json([C_ADD, C_FAR.merge(body: "Something else entirely.")])}
post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "keep" => %w[0 1], "_csrf" => token}
check("findings reworded since the page: nothing drafted", writes, [])
get "/sessions/draft?id=#{job["id"]}"
check("and it says so", last_response.body.include?("changed since this page loaded"), true)
$box = {ok: true, head: HEAD, json: json([C_ADD, C_FAR])}

post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "keep" => %w[0 1], "_csrf" => token}
check("all ticked, the review is drafted", writes.map { |c| [c[0], c[2]] }, [["github_pat_WRITE", "/repos/#{REPO}/pulls/6503/reviews"]])
check("with the line comment", writes.last[3][:comments], [C_ADD])
check("and the other in the summary", writes.last[3][:body].include?("this loop never ends"), true)

$calls.clear
post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "keep" => %w[0], "_csrf" => token}
check("unticked, one for the summary is not in it", writes.last[3][:body].include?("this loop never ends"), false)
check("and the ticked one still goes", writes.last[3][:comments], [C_ADD])
get "/sessions/draft?id=#{job["id"]}"
check("the page says what was left out", last_response.body.include?("leaving out the 1 you unticked"), true)
kept = JSON.parse(DB.row("SELECT draft_json FROM review_jobs WHERE id = $1", [job["id"]])["draft_json"], symbolize_names: true)
check("what was sent is kept, to learn from what you submit",
      [kept[:review_id], kept[:sent], kept[:unticked]], [77, [C_ADD], [C_FAR]])
check("the summary as sent, without the footer", kept[:summary], "One real problem.")
check("the page says it will learn from it", last_response.body.include?("what you changed is learned from"), true)

$calls.clear
post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "keep" => %w[1], "_csrf" => token}
check("unticked, a line comment is not sent", writes.last[3][:comments], [])
$calls.clear
post "/sessions/draft?id=#{job["id"]}", {"digest" => digest, "_csrf" => token}
check("none ticked: the summary alone", [writes.last[3][:comments], writes.last[3][:body].start_with?("One real problem.")], [[], true])
get "/sessions/draft?id=#{job["id"]}"
check("the page links to it", last_response.body.include?("pullrequestreview-77"), true)
get "/sessions"
check("so does the card", last_response.body.include?("drafted on GitHub"), true)

$box = {ok: true, head: HEAD, json: nil}
github
get "/sessions/draft?id=#{job["id"]}"
check("an older review offers to ask the box", last_response.body.include?("Ask the box to write them"), true)
post "/sessions/draft/ask?id=#{job["id"]}", {"_csrf" => form.(last_response.body, "/sessions/draft/ask")}
check("which sends it a follow-up", $asked.last.to_s.include?(".rq/review.json"), true)
check("and the review is working again", DB.row("SELECT state FROM review_jobs WHERE id = $1", [job["id"]])["state"], "running")
get "/sessions/draft?id=#{job["id"]}"
check("while it works, the page waits", last_response.body.include?("still working on this review"), true)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
