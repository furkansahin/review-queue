#!/usr/bin/env ruby
# detail() review-state extraction:  bundle exec ruby test_state_detail.rb
require_relative "queue_service"
require "time"

ME = "furkansahin"
NOW = Time.now.utc
def iso(t) = t.utc.iso8601

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-8s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end

# head commit is 2 days old; anything approved before that reviewed older code
HEAD_AT = NOW - 2 * 86_400

def build(reviews:, requested: [], teams: [], author: ME)
  svc = QueueService.new(token: "x", scope: "s", label: "")
  gh = svc.instance_variable_get(:@gh)
  pull = {
    "head" => {"sha" => "abc"}, "created_at" => iso(NOW - 10 * 86_400),
    "user" => {"login" => author}, "draft" => false,
    "requested_reviewers" => requested.map { |u| {"login" => u} },
    "requested_teams" => teams.map { |t| {"name" => t} },
    "changed_files" => 1, "additions" => 5, "deletions" => 5
  }
  gh.define_singleton_method(:get) do |path|
    case path
    when %r{/pulls/\d+\z} then pull
    when %r{/reviews} then reviews
    when %r{/commits/abc\z} then {"commit" => {"committer" => {"date" => iso(HEAD_AT)}}}
    else []
    end
  end
  gh.define_singleton_method(:try) { |path| path.include?("check-runs") ? {"check_runs" => []} : get(path) }
  item = {"html_url" => "u", "title" => "t", "number" => 1,
          "repository_url" => "https://api.github.com/repos/o/r", "labels" => []}
  svc.send(:detail, {item: item, buckets: [:mine]}, ME)
end

def review(who, state, days_ago) = {"user" => {"login" => who}, "state" => state,
                                    "submitted_at" => iso(NOW - days_ago * 86_400)}

check("requested reviewer sets awaiting_review",
      build(reviews: [], requested: ["alice"])[:awaiting_review], true)
check("requested TEAM also sets awaiting_review",
      build(reviews: [], teams: ["infra"])[:awaiting_review], true)
check("nobody requested -> awaiting_review false",
      build(reviews: [])[:awaiting_review], false)

check("approval after the head commit counts",
      build(reviews: [review("alice", "APPROVED", 1)])[:approved], true)
check("approval BEFORE the head commit is stale, so it does not count",
      build(reviews: [review("alice", "APPROVED", 5)])[:approved], false)
check("a later comment replaces an earlier approval",
      build(reviews: [review("alice", "APPROVED", 1), review("alice", "COMMENTED", 0)])[:approved], false)
check("a later approval replaces an earlier comment",
      build(reviews: [review("alice", "COMMENTED", 1), review("alice", "APPROVED", 0)])[:approved], true)
check("one approver is enough among several reviewers",
      build(reviews: [review("alice", "COMMENTED", 1), review("bob", "APPROVED", 0)])[:approved], true)
check("changes requested is not an approval",
      build(reviews: [review("alice", "CHANGES_REQUESTED", 0)])[:approved], false)
check("a pending review is ignored",
      build(reviews: [review("alice", "PENDING", 0)])[:approved], false)
check("a review with no submitted_at is ignored",
      build(reviews: [{"user" => {"login" => "a"}, "state" => "APPROVED", "submitted_at" => nil}])[:approved], false)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
