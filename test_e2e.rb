#!/usr/bin/env ruby
# E2E on a fork's pull request:  bundle exec ruby test_e2e.rb
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

REPO = "ubicloud/ubicloud"
SHA = "a1" * 20
NEWER = "b2" * 20
BRANCH = "furkan/enescakir-fix/dns"

# GitHub, answered from a table by verb and path, with every call written
# down -- which token made it too, once it goes through the app.
$routes = {}
$calls = []
def answer(token, verb, path, body = nil)
  $calls << [token, verb, path, body]
  v = $routes.fetch([verb, path]) { raise %(GitHub 404 on #{path}: {"message":"Not Found"}) }
  v = v.call(body) if v.is_a?(Proc)
  raise v if v.is_a?(String)
  v
end
class FakeGH
  def initialize(token = "t") = (@token = token)
  def get(path) = answer(@token, :get, path)
  def try(path) = (answer(@token, :get, path) rescue nil)
  def post(path, body) = answer(@token, :post, path, body)
  def patch(path, body) = answer(@token, :patch, path, body)
end

def pull(state: "open", head_repo: "EnesCakir/ubicloud", sha: SHA, merged: false)
  {"state" => state, "merged_at" => (merged ? "2026-09-28T10:00:00Z" : nil), "title" => "Fix the DNS thing",
   "html_url" => "https://github.com/#{REPO}/pull/6532",
   "head" => {"repo" => head_repo && {"full_name" => head_repo}, "user" => {"login" => "EnesCakir"},
              "ref" => "fix/dns", "sha" => sha, "label" => "EnesCakir:fix/dns"}}
end
FILES = "/repos/#{REPO}/pulls/6532/files?per_page=100&page=1"
REF = "/repos/#{REPO}/git/ref/heads/furkan/enescakir-fix/dns"
DISPATCH = "/repos/#{REPO}/actions/workflows/e2e.yml/dispatches"
RUN = "https://github.com/#{REPO}/actions/runs/42"
def github(pull: pull(), files: [{"filename" => "prog/vm.rb"}], ref: nil)
  $calls.clear
  $routes = {[:get, "/repos/#{REPO}/pulls/6532"] => pull, [:get, FILES] => files,
             [:get, "/user"] => {"login" => "furkansahin", "name" => "Furkan Sahin"},
             [:post, "/repos/#{REPO}/git/refs"] => {"ref" => "refs/heads/#{BRANCH}"},
             [:patch, "/repos/#{REPO}/git/refs/heads/furkan/enescakir-fix/dns"] => {"ref" => "refs/heads/#{BRANCH}"},
             [:post, DISPATCH] => {"workflow_run_id" => 42, "html_url" => RUN}}
  $routes[[:get, REF]] = {"object" => {"sha" => ref}} if ref
end
def writes = $calls.reject { |c| c[1] == :get }

puts "-- whose branch --"
check("the first word of your name", E2E.prefix({"name" => "Furkan Sahin", "login" => "furkansahin"}), "furkan")
check("in plain letters", E2E.prefix({"name" => "Şükrü Öz", "login" => "sukru"}), "sukru")
check("or your login, with no name", E2E.prefix({"name" => nil, "login" => "Mohi-Kalantari"}), "mohi-kalantari")
check("their login and their branch after it", E2E.branch_for("furkan", "EnesCakir", "fix/dns"), BRANCH)

puts "-- what it would do --"
github
plan = E2E.plan(FakeGH.new, REPO, 6532, "furkan")
check("reads their head", [plan[:owner], plan[:ref], plan[:sha]], ["EnesCakir", "fix/dns", SHA])
check("names the branch", plan[:branch], BRANCH)
check("a new one", plan[:existing], nil)
check("and it leaves .github/ alone", plan[:touches_ci], false)
github(ref: NEWER)
check("or the one pushed before", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:existing], NEWER)
github(pull: pull(head_repo: REPO))
check("a branch of the repository itself: /run-e2e", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:error].to_s.include?("/run-e2e"), true)
github(pull: pull(head_repo: nil))
check("a fork since deleted is still a fork", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:branch], BRANCH)
github(pull: pull(state: "closed", merged: true))
check("a merged one is refused", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:error], "#6532 is merged")
github(files: [{"filename" => ".github/workflows/e2e.yml"}])
check("one that changes .github/ is marked", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:touches_ci], true)
github(files: [{"filename" => "ci.yml", "previous_filename" => ".github/workflows/ci.yml"}])
check("so is one that moves a file out of it", E2E.plan(FakeGH.new, REPO, 6532, "furkan")[:touches_ci], true)

puts "-- doing it --"
github
res = E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: %w[metal aws gcp])
check("it runs", res[:ok], true)
check("the branch is made at their exact commit", writes.first[3], {ref: "refs/heads/#{BRANCH}", sha: SHA})
check("and E2E dispatched on it, on every provider", writes.last[3],
      {ref: BRANCH, inputs: {providers: "metal,aws,gcp"}, return_run_details: true})
check("and nothing else written", writes.map { |c| [c[1], c[2]] },
      [[:post, "/repos/#{REPO}/git/refs"], [:post, DISPATCH]])
check("with the run to follow", res[:run_url], RUN)

github(ref: NEWER)
E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: %w[metal])
check("a branch from before follows their head", writes.first[1..], [:patch, "/repos/#{REPO}/git/refs/heads/furkan/enescakir-fix/dns", {sha: SHA, force: true}])
check("on the providers asked for", writes.last[3][:inputs], {providers: "metal"})
github(ref: SHA)
E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: %w[metal])
check("one already there is only run again", writes.map { |c| c[2] }, [DISPATCH])

puts "-- and not doing it --"
github
res = E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: NEWER, providers: %w[metal])
check("a commit other than the one shown is refused", res[:error].to_s.include?("moved on"), true)
check("before anything is written", writes, [])
github(files: [{"filename" => ".github/actions/setup/action.yml"}])
res = E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: %w[metal])
check("so is one that changes .github/", [res[:error].to_s.include?(".github/"), writes], [true, []])
github
res = E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: ["gcp;curl evil"])
check("providers are only the known ones", [res[:error], writes], ["pick at least one provider", []])
github
$routes[[:post, DISPATCH]] = %(GitHub 403 on #{DISPATCH}: {"message":"Resource not accessible by personal access token"})
res = E2E.run(FakeGH.new, E2E.plan(FakeGH.new, REPO, 6532, "furkan"), sha: SHA, providers: %w[metal])
check("a token that cannot dispatch says what it needs", res[:error].to_s.include?("Actions: Read and write"), true)
check("and that the branch was pushed", res[:error].to_s.start_with?("pushed #{BRANCH}"), true)

puts "-- through the app --"
include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
GitHubClient.class_eval do
  define_method(:get) { |path| path == "/user" && $routes.empty? ? {"login" => "furkansahin"} : answer(@token, :get, path) }
  define_method(:try) { |path| answer(@token, :get, path) rescue nil }
  define_method(:post) { |path, body| answer(@token, :post, path, body) }
  define_method(:patch) { |path, body| answer(@token, :patch, path, body) }
end
ROWS = [
  {key: "#{REPO}#6532", repo: "ubicloud", repo_full: REPO, number: 6532, fork: "EnesCakir:fix/dns"},
  {key: "#{REPO}#6533", repo: "ubicloud", repo_full: REPO, number: 6533, fork: nil}
].map do |r|
  r.merge(last_at: Time.now - 3600, settled: false, draft: false, buckets: [:review], quick: false,
          url: "https://github.com/#{REPO}/pull/#{r[:number]}", title: "PR #{r[:number]}", ref: "ubicloud ##{r[:number]}",
          author: "someone", state: "Your turn", state_bg: "var(--x)", state_color: "var(--x)", chips: [],
          row_bg: "var(--row)", age_color: "var(--x)", age_text_color: "var(--x)", age: "1h", read_est: "~1m",
          size_sub: "±5 · 1f", last_who: "someone", last_what: "comment", my_action: "never", my_action_kind: nil,
          ci: "pass", ci_color: "var(--ci-pass)")
end
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: ROWS, counts: counts(ROWS), login: "furkansahin", fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: []}
  end
end
DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
$routes = {}
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
DB.exec(<<~SQL, ["furkansahin", Crypto.encrypt("github_pat_WRITE")])
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key, github_write_token_enc)
  VALUES ($1, '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA', $2)
SQL

get "/"
check("a fork's row offers it", last_response.body.include?(%(href="/e2e?repo=#{REPO}&amp;pr=6532")), true)
check("saying whose branch", last_response.body.include?("from EnesCakir:fix/dns"), true)
check("a branch's row does not", last_response.body.include?("pr=6533"), false)

github
get "/e2e?repo=#{REPO}&pr=6532"
page = last_response.body
check("the page says which commit", page.include?(SHA[0, 10]), true)
check("becomes which branch", page.include?(BRANCH), true)
check("and can do it", page.match?(/<button class="go" type="submit" disabled/), false)
check("it read GitHub with the session's token", $calls.map(&:first).uniq, ["gho_session"])
check("and wrote nothing", writes, [])
get "/e2e?repo=someone/else&pr=6532"
check("a repository outside the scope is not offered", last_response.status, 302)

token = page[/name="_csrf" value="([^"]+)"/, 1]
post "/e2e?repo=#{REPO}&pr=6532", {"sha" => SHA, "providers" => %w[metal aws gcp]}
check("without its token it is refused", last_response.status, 403)
check("before anything is written", writes, [])
post "/e2e?repo=#{REPO}&pr=6532", {"sha" => SHA, "providers" => %w[metal aws gcp], "_csrf" => token}
check("confirmed, it goes back to the page", last_response.location, "/e2e?repo=#{REPO}&pr=6532")
check("having written the branch and the dispatch", writes.map { |c| c[2] }, ["/repos/#{REPO}/git/refs", DISPATCH])
check("with the write token", writes.map(&:first).uniq, ["github_pat_WRITE"])
get "/e2e?repo=#{REPO}&pr=6532"
check("which says so", last_response.body.include?("pushed #{BRANCH} and started E2E on it"), true)
check("with the run to follow", last_response.body.include?(%(href="#{RUN}")), true)

github(pull: pull(sha: NEWER))
post "/e2e?repo=#{REPO}&pr=6532", {"sha" => SHA, "providers" => %w[metal], "_csrf" => token}
check("pushed to since the page loaded: nothing written", writes, [])
get "/e2e?repo=#{REPO}&pr=6532"
check("and it says why", last_response.body.include?("has moved on since you looked"), true)

DB.exec("UPDATE bayboxes SET github_write_token_enc = NULL")
github
get "/e2e?repo=#{REPO}&pr=6532"
check("without a write token the button waits", last_response.body.include?("needs a write token"), true)
check("and cannot be pressed", last_response.body.match?(/<button class="go" type="submit" disabled/), true)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
