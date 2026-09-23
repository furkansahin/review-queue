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
puts "-- a rebuild must not make everyone else queue --"
# build takes seconds against GitHub. A second reader arriving during one is
# handed the snapshot that already exists instead of waiting for the fetch.
slow = QueueService.new(token: "x", scope: "s", label: "", ttl: 0)
builds = 0
started = Queue.new
release = Queue.new
slow.define_singleton_method(:build) do
  builds += 1
  started << true
  release.pop
  {rows: [], login: ME, fetched_at: Time.now, rate: nil, error: nil, counts: {}, reviews_7d: nil}
end

release << true
first = slow.snapshot                      # one real build, to have something to serve
started.pop                                # drain its marker, so the next pop means the next build
check("the first call builds", builds, 1)
check("and returns a snapshot", first.is_a?(Hash), true)

rebuild = Thread.new { slow.snapshot(force: true) }
started.pop                                # the rebuild is now inside build, holding the lock
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
during = slow.snapshot                     # an ordinary page load arriving mid-rebuild
waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
check("a reader during a rebuild is served at once", waited < 0.2, true)
check("with the snapshot we already had", during.equal?(first), true)
check("and did not start a second build", builds, 2)
release << true
check("the rebuild still produced a new snapshot", rebuild.value.equal?(first), false)

puts "-- an old snapshot is served at once, and rebuilt behind it --"
# The slowness: every page answered in ~40ms except the first after the five
# minutes ran out, which waited out the whole rebuild -- 6.8s on the live site.
swr = QueueService.new(token: "x", scope: "s", label: "", ttl: 300)
made = 0
starts = Queue.new
gate = Queue.new
fail_with = nil
swr.define_singleton_method(:build) do
  made += 1
  starts << made
  gate.pop
  raise fail_with if fail_with
  {rows: [{key: "o/r##{made}"}], login: ME, fetched_at: Time.now, rate: nil, error: nil, counts: {}, reviews_7d: nil, built: made}
end
wait_until = lambda do |limit = 2.0, &cond|
  deadline = Time.now + limit
  sleep 0.01 until cond.call || Time.now > deadline
  cond.call
end

gate << true
first = swr.snapshot
starts.pop
check("the very first load waits for its build", first[:built], 1)
old = first.merge(fetched_at: Time.now - 600)
swr.instance_variable_set(:@snapshot, old)
# In a thread with a deadline: if a stale read ever waits on the build again,
# this fails instead of hanging on the gate.
reader = Thread.new { swr.snapshot }
got = reader.join(0.2) && reader.value
check("an old snapshot is served without waiting", !got.nil?, true)
gate << true unless got   # let a blocked read go, so the rest can report
check("the one that was there", got.equal?(old), true)
check("and a rebuild starts behind it", starts.pop, 2)
check("which the page can see", swr.refreshing?, true)
3.times { swr.snapshot }
sleep 0.05
check("more loads meanwhile start no second rebuild", made, 2)
# Refresh pressed while that rebuild runs: it waits -- it asked for fresh --
# but for the rebuild already under way, not a second one.
forced = Thread.new { swr.snapshot(force: true) }
sleep 0.05
gate << true
check("Refresh gets the rebuild that was running", forced.value[:built], 2)
check("without building again", made, 2)
check("the page stops saying refreshing", wait_until.call { !swr.refreshing? }, true)
check("and the next load has the new rows", swr.snapshot[:built], 2)

# A rebuild behind the page that fails keeps the rows it had, and carries the
# failure to the next load -- which is the first that can act on it.
fail_with = GitHubClient::Unauthorized.new("GitHub 401 on /user: Bad credentials")
swr.instance_variable_set(:@snapshot, swr.snapshot.merge(fetched_at: Time.now - 600))
swr.snapshot
starts.pop
gate << true
wait_until.call { !swr.refreshing? }
after = swr.snapshot
check("a failed rebuild keeps the rows", after[:rows], [{key: "o/r#2"}])
check("and says why", after[:error].to_s.include?("401"), true)
check("so the next load sends you to sign in again", after[:unauthorized], true)

puts "-- approved: waiting to be merged --"
# GitHub's own decision, under the repository's rules. nil means it could not
# be asked.
ready = lambda do |mine:, decision:, i_acted: false, awaiting: false, approved: false, draft: false, mergeable: nil|
  x = pr(mine: mine, i_acted: i_acted, awaiting: awaiting, approved: approved, draft: draft)
  x[:review_decision] = decision
  x[:mergeable] = mergeable
  x[:approved_at] = NOW - 5 * 86_400
  SVC.send(:row, x, ME)
end
r = ready.(mine: false, decision: "APPROVED")
check("someone else's, approved -> To be merged", r[:state], "To be merged")
check("which is not your work", r[:settled], true)
check("and sinks with the settled rows", r[:sort_key][0], 2)
check("its wait is counted from the approval", r[:age], "5d")
r = ready.(mine: false, decision: "APPROVED", awaiting: true)
check("even with you still requested", r[:state], "To be merged")
r = ready.(mine: true, decision: "APPROVED")
check("yours, approved -> Ready to merge", r[:state], "Ready to merge")
check("which is yours to do", r[:settled], false)
check("so it is work, at the top", r[:sort_key][0], 0)
check("and the page knows it is ready", r[:ready], true)
r = ready.(mine: true, decision: "APPROVED", awaiting: true)
check("approved beats a pending reviewer", r[:state], "Ready to merge")
check("a draft is never ready, whatever its reviews", ready.(mine: false, decision: "APPROVED", draft: true)[:state], "To review")
check("changes requested is not ready", ready.(mine: false, decision: "CHANGES_REQUESTED")[:state], "To review")
check("review required is not ready", ready.(mine: false, decision: "REVIEW_REQUIRED")[:state], "To review")
# GitHub's decision over the reviews' own story, both ways: the reviews said
# approved on a pull request the rules did not count as approved...
check("GitHub says review required, reviews say approved -> Waiting on them",
      ready.(mine: true, decision: "REVIEW_REQUIRED", awaiting: true, approved: true)[:state], "Waiting on them")
# ...and when GitHub cannot be asked, nothing is called ready on a guess --
# that would take a pull request off your list while it may still need you.
check("no decision, reviews say approved: not ready", ready.(mine: false, decision: nil, approved: true)[:state], "To review")
check("and yours falls back to what it was", ready.(mine: true, decision: nil, approved: true, awaiting: true)[:state], "Your turn")
chips = ->(row) { row[:chips].map { |c| c[:text] } }
check("approved with conflicts says so", chips.(ready.(mine: false, decision: "APPROVED", mergeable: "CONFLICTING")), ["conflicts"])
check("approved and mergeable does not", chips.(ready.(mine: false, decision: "APPROVED", mergeable: "MERGEABLE")), [])
check("conflicts are not flagged on unapproved work", chips.(ready.(mine: false, decision: "REVIEW_REQUIRED", mergeable: "CONFLICTING")), [])

puts "-- asking GitHub for the decisions --"
asked = []
gh = SVC.instance_variable_get(:@gh)
gh.define_singleton_method(:graphql) do |_q, vars|
  asked << vars[:ids].size
  {"nodes" => vars[:ids].map { |id| {"id" => id, "reviewDecision" => "APPROVED", "mergeable" => "MERGEABLE"} } + [nil]}
end
got = SVC.send(:review_decisions, (1..150).map { |i| "PR_#{i}" } + [nil, "PR_1"])
check("in batches of a hundred", asked, [100, 50])
check("one answer per pull request", got.size, 150)
check("keyed by node id", got["PR_7"], {decision: "APPROVED", mergeable: "MERGEABLE"})
gh.define_singleton_method(:graphql) { |*_| raise "GitHub 502" }
check("a failure is an empty answer, never an exception", SVC.send(:review_decisions, ["PR_1"]), {})

puts "-- the activity columns --"
# Who and what used to share one line, "someone · changes requested", and
# were cut short on most rows. Now who is one line and what-and-when the next.
other = pr(mine: false, i_acted: false, awaiting: true)
other[:last] = {at: NOW - 12 * 86_400, who: "macieksarnowicz", kind: "changes requested"}
r = SVC.send(:row, other, ME)
check("who acted last is a line of its own", r[:last_who], "macieksarnowicz")
check("and what they did, and when, the next", r[:last_what], "changes requested · 12d ago")
check("when it was you, it says so", SVC.send(:row, pr(mine: true, i_acted: true, awaiting: false), ME)[:last_who], "you")
never = pr(mine: false, i_acted: false, awaiting: true)
never[:my_last] = nil
nr = SVC.send(:row, never, ME)
check("never acted reads never", nr[:my_action], "never")
# "never" and then "no activity from you" said the same thing twice, and the
# second was the widest text in its column.
check("with nothing repeated under it", nr[:my_action_kind], nil)
check("the old combined fields are gone", r.key?(:last_actor) || r.key?(:last_activity), false)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
