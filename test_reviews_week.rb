#!/usr/bin/env ruby
# Weekly review counter tests:  bundle exec ruby test_reviews_week.rb
require_relative "queue_service"

NOW = Time.now
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end

def ev(type, repo, num, days_ago)
  {"type" => type, "repo" => {"name" => repo},
   "created_at" => (NOW - days_ago * 86_400).utc.iso8601,
   "payload" => {"pull_request" => {"number" => num}}}
end

# A client that returns canned pages.
def svc_with(pages, scope: "repo:ubicloud/ubicloud")
  s = QueueService.new(token: "x", scope: scope, label: "l")
  gh = s.instance_variable_get(:@gh)
  gh.define_singleton_method(:try) do |path|
    page = path[/[&?]page=(\d+)/, 1].to_i   # not per_page
    pages[page - 1]
  end
  s
end

R = "ubicloud/ubicloud"

# counts distinct PRs inside the window, ignores other event types
page = [ev("PullRequestReviewEvent", R, 1, 1), ev("PullRequestReviewEvent", R, 2, 3),
        ev("PullRequestReviewEvent", R, 1, 2),            # same PR twice -> one
        ev("PushEvent", R, 9, 1), ev("IssueCommentEvent", R, 8, 1),
        ev("PullRequestReviewEvent", R, 3, 30)]           # outside the window
check("counts distinct PRs in the window",
      svc_with([page]).send(:reviews_this_week, "me", now: NOW), {count: 2, complete: true})

# a review on a repo outside RQ_SCOPE is ignored
page = [ev("PullRequestReviewEvent", R, 1, 1), ev("PullRequestReviewEvent", "other/repo", 2, 1),
        ev("PullRequestReviewEvent", R, 5, 40)]
check("ignores repos outside RQ_SCOPE",
      svc_with([page]).send(:reviews_this_week, "me", now: NOW), {count: 1, complete: true})

# org: scope matches every repo of that owner
page = [ev("PullRequestReviewEvent", "ubicloud/other", 1, 1), ev("PullRequestReviewEvent", "x/y", 2, 1),
        ev("PullRequestReviewEvent", R, 5, 40)]
check("org: scope matches the whole owner",
      svc_with([page], scope: "org:ubicloud").send(:reviews_this_week, "me", now: NOW), {count: 1, complete: true})

# every event is inside the window -> the count is a floor, not a total
page = Array.new(100) { |i| ev("PullRequestReviewEvent", R, i, 0.5) }
check("marks the count incomplete when the page is all recent",
      svc_with([page, [], []]).send(:reviews_this_week, "me", now: NOW), {count: 100, complete: false})

# reads more pages only while it needs them
page1 = Array.new(100) { |i| ev("PullRequestReviewEvent", R, i, 1) }
page2 = [ev("PullRequestReviewEvent", R, 500, 40)]
check("reads a second page to reach past the cutoff",
      svc_with([page1, page2]).send(:reviews_this_week, "me", now: NOW), {count: 100, complete: true})

# the feed cannot be read -> nil, and the page shows nothing
check("returns nil when the feed fails", svc_with([nil]).send(:reviews_this_week, "me", now: NOW), nil)

# an empty feed is still a real answer
check("empty feed counts zero", svc_with([[]]).send(:reviews_this_week, "me", now: NOW), {count: 0, complete: false})

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
