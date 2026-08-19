#!/usr/bin/env ruby
# Row state tests:  bundle exec ruby test_state.rb
require_relative "queue_service"

ME = "furkansahin"
SVC = QueueService.new(token: "x", scope: "s", label: "")
NOW = Time.now
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-18s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end

# Builds the hash detail() produces, so row() runs its real logic.
def pr(mine:, i_acted:, awaiting:, approved: false, draft: false, days: 3)
  at = NOW - days * 86_400
  ev = ->(who) { {at: at, who: who, kind: "comment"} }
  {url: "u", title: "t", number: 1, repo: "o/r", owner: "o", author: mine ? ME : "someone",
   draft: draft, ci: :pass, labels: [], buckets: [:review], mine: mine,
   last: ev.(mine ? ME : "someone"), my_last: ev.(ME), last_other: ev.("someone"),
   i_acted: i_acted, awaiting_review: awaiting, approved: approved,
   changed: 1, churn: 10}
end
state = ->(**kw) { SVC.send(:row, pr(**kw), ME)[:state] }
settled = ->(**kw) { SVC.send(:row, pr(**kw), ME)[:settled] }
tier = ->(**kw) { SVC.send(:row, pr(**kw), ME)[:sort_key][0] }

puts "-- my pull requests --"
check("reviewers requested, none approved -> Waiting on them",
      state.(mine: true, i_acted: true, awaiting: true), "Waiting on them")
check("mohi's case: I replied, nobody requested -> Your turn",
      state.(mine: true, i_acted: true, awaiting: false), "Your turn")
check("one approval beats a pending reviewer -> Your turn",
      state.(mine: true, i_acted: true, awaiting: true, approved: true), "Your turn")
check("approved and nothing pending -> Your turn",
      state.(mine: true, i_acted: false, awaiting: false, approved: true), "Your turn")
check("never requested anyone -> Your turn",
      state.(mine: true, i_acted: false, awaiting: false), "Your turn")

puts "-- other people's pull requests: rule unchanged --"
check("I acted last -> Reviewed", state.(mine: false, i_acted: true, awaiting: false), "Reviewed")
check("they acted last -> To review", state.(mine: false, i_acted: false, awaiting: false), "To review")
check("requested_reviewers does not affect others",
      state.(mine: false, i_acted: true, awaiting: true), "Reviewed")
check("an approval does not affect others",
      state.(mine: false, i_acted: false, awaiting: false, approved: true), "To review")

puts "-- settled drives sorting and Hide settled, not only the word --"
check("mohi's case is NOT settled", settled.(mine: true, i_acted: true, awaiting: false), false)
check("waiting on them IS settled", settled.(mine: true, i_acted: true, awaiting: true), true)

puts "-- drafts are listed, but below the work --"
check("active work is tier 0", tier.(mine: false, i_acted: false, awaiting: false), 0)
check("draft is tier 1", tier.(mine: false, i_acted: false, awaiting: false, draft: true), 1)
check("settled is tier 2", tier.(mine: false, i_acted: true, awaiting: false), 2)
check("my draft is still tier 1", tier.(mine: true, i_acted: true, awaiting: false, draft: true), 1)
check("a settled draft sinks to tier 2", tier.(mine: false, i_acted: true, awaiting: false, draft: true), 2)

puts "-- the whole list orders work, then drafts, then settled --"
rows = [pr(mine: false, i_acted: true,  awaiting: false, days: 30),          # settled, very old
        pr(mine: false, i_acted: false, awaiting: false, draft: true, days: 20),
        pr(mine: false, i_acted: false, awaiting: false, days: 1),
        pr(mine: true,  i_acted: true,  awaiting: false, days: 5)]           # mohi's case
sorted = rows.map { |p| SVC.send(:row, p, ME) }.sort_by { |r| r[:sort_key] }
check("order is work, work, draft, settled",
      sorted.map { |r| r[:sort_key][0] }, [0, 0, 1, 2])
check("oldest work still comes first", sorted.first[:state], "Your turn")

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
