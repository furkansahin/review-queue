#!/usr/bin/env ruby
# Issues tab tests:  bundle exec ruby test_issues.rb
require_relative "queue_service"

ME = "furkansahin"
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end

def pr(n, state, draft: false, author: "someone") =
  {"number" => n, "title" => "pr #{n}", "url" => "https://github.com/o/r/pull/#{n}",
   "state" => state, "isDraft" => draft, "author" => {"login" => author}}

def issue(n, linked: [], mentioned: [], updated: Time.now - 3600, title: "issue #{n}")
  {"number" => n, "title" => title, "url" => "https://github.com/o/r/issues/#{n}",
   "updatedAt" => updated.utc.iso8601, "author" => {"login" => "reporter"},
   "repository" => {"nameWithOwner" => "o/r"}, "labels" => {"nodes" => [{"name" => "bug"}]},
   "closedByPullRequestsReferences" => {"nodes" => linked},
   "timelineItems" => {"nodes" => mentioned.map { |p| {"source" => p} } + [{"source" => {}}]}}
end

svc = QueueService.new(token: "x", scope: "repo:o/r", label: "")

puts "-- the tab and its query --"
keys = svc.tabs.map { |t| t[:key] }
check("issues is a tab", keys.include?(:issues), true)
check("labelled like My PRs", svc.tabs.find { |t| t[:key] == :issues }[:label], "My issues")
q = svc.issues_query
check("scoped", q.include?("repo:o/r"), true)
check("open issues only", q.include?("is:open") && q.include?("is:issue"), true)
check("assigned to the signed-in user", q.include?("assignee:@me"), true)

puts "-- one issue per state --"
rows = svc.send(:issue_rows, [
  issue(1),
  issue(2, linked: [pr(20, "OPEN", author: ME)]),
  issue(3, mentioned: [pr(30, "OPEN", draft: true)]),
  issue(4, linked: [pr(40, "MERGED")]),
  issue(5, linked: [pr(50, "CLOSED")], mentioned: [pr(51, "CLOSED")]),
  issue(6, linked: [pr(60, "OPEN")], mentioned: [pr(60, "OPEN")])
], ME)
by = rows.to_h { |r| [r[:number], r] }
check("nothing on it is To do", by[1][:state], "To do")
check("and it is not settled", by[1][:settled], false)
check("a linked open pull request is PR open", by[2][:state], "PR open")
check("your own is shown as yours", by[2][:prs].first[:author], "you")
check("a mention counts too", by[3][:state], "PR open")
check("and is marked as only a mention", by[3][:prs].first[:linked], false)
check("a draft reads as draft", by[3][:prs].first[:state], "draft")
check("a merged link is PR merged", by[4][:state], "PR merged")
# A linked attempt that was closed is worth knowing; a mention that was closed
# is a pull request that talked about the issue and went nowhere.
check("a closed link is kept", by[5][:prs].map { |p| p[:number] }, [50])
check("and does not make the issue in progress", by[5][:state], "To do")
check("one pull request linked and mentioned is listed once", by[6][:prs].size, 1)
check("as linked", by[6][:prs].first[:linked], true)
check("an empty timeline event is ignored", by[1][:prs], [])
check("keys match the jobs' repo#number", by[1][:key], "o/r#1")
check("links to the issue", by[1][:url], "https://github.com/o/r/issues/1")

puts "-- order --"
check("to do first", rows.first[:state], "To do")
check("then in flight, then landed", rows.map { |r| r[:state] }.uniq, ["To do", "PR open", "PR merged"])
older = svc.send(:issue_rows, [issue(7, updated: Time.now - 86_400 * 9), issue(8, updated: Time.now - 60)], ME)
check("newest activity first within a state", older.map { |r| r[:number] }, [8, 7])

puts "-- a failure is shown, not hidden --"
gh = svc.instance_variable_get(:@gh)
gh.define_singleton_method(:rate_remaining) { 5000 }
gh.define_singleton_method(:get) do |path|
  path == "/user" ? {"login" => ME} : {"items" => []}
end
gh.define_singleton_method(:try) { |path| path.include?("events") ? [] : {"items" => []} }
gh.define_singleton_method(:graphql) { |*_| raise "GitHub GraphQL: something broke" }
snap = svc.snapshot(force: true)
check("the queue still builds", snap[:error], nil)
check("the issues are unknown, not empty", snap[:issues], nil)
check("and the reason is kept", snap[:issues_error].to_s.include?("something broke"), true)

gh.define_singleton_method(:graphql) do |query, vars|
  $asked = [query, vars]
  {"search" => {"nodes" => [issue(9), nil, {}]}}
end
snap = svc.snapshot(force: true)
check("they arrive in the same rebuild", snap[:issues].map { |r| r[:number] }, [9])
check("asked with the issues query", $asked[1][:q], svc.issues_query)
check("the query asks for linked pull requests", $asked[0].include?("closedByPullRequestsReferences"), true)
check("no error when it works", snap[:issues_error], nil)

puts "-- GraphQL errors are errors --"
client = GitHubClient.new("x")
client.define_singleton_method(:post) { |*_| {"data" => nil, "errors" => [{"message" => "Field 'nope' doesn't exist"}]} }
raised = begin
  client.graphql("{ nope }")
  nil
rescue StandardError => e
  e.message
end
# GitHub answers a bad query with 200, so without this it reads as no issues.
check("a 200 with errors raises", raised.to_s.include?("Field 'nope'"), true)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
