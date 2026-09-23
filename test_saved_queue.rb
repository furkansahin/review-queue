#!/usr/bin/env ruby
# The saved queue:  DATABASE_URL=... bundle exec ruby test_saved_queue.rb
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
require "rack/test"
require_relative "app"

ME = "furkansahin"
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-60s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end
def raises(klass)
  yield
  "no error"
rescue klass => e
  e.message
end
def wait_until(limit = 3.0)
  deadline = Time.now + limit
  sleep 0.01 until yield || Time.now > deadline
  yield
end

DB.exec("DELETE FROM saved_queues")

puts "-- the codec: exactly what went in, and never code --"
t = Time.at(1_789_000_000, 123_456_789, :nsec)
snap = {login: ME, fetched_at: t, rate: "4990", error: nil, issues_error: nil,
        rows: [{key: "o/r#1", buckets: [:review, :label], sort_key: [0, Float::INFINITY], last_at: t,
                chips: [{text: "clickhouse", bg: "var(--x)"}], quick: false, churn: 12,
                title: "Handle \u0000 and ünïcødé and \"quotes\"", my_action_kind: nil}],
        counts: {all: {open: 1, total: 2}}, merged: [], reviews_7d: {count: 3, complete: true}}
back = SnapshotCodec.load(SnapshotCodec.dump(snap))
check("comes back identical", back == snap, true)
check("times to the nanosecond", back[:fetched_at].nsec, 123_456_789)
check("symbols stay symbols", back[:rows][0][:buckets], [:review, :label])
check("a row with no events still sorts last", back[:rows][0][:sort_key], [0, Float::INFINITY])
check("a string key is refused, not quietly turned into a symbol",
      raises(ArgumentError) { SnapshotCodec.dump({"key" => 1}) }.include?("not a symbol"), true)
check("so is anything JSON cannot say", raises(ArgumentError) { SnapshotCodec.dump({x: Object.new}) }.include?("cannot hold"), true)
# The reason it is JSON: what is read back is data, whatever the row holds.
evil = %({"login":"#{ME}","rows":[{"$sym":"system"}],"x":{"^o":"Kernel","json_class":"Kernel"}})
check("a crafted row is only ever data", SnapshotCodec.load(evil)[:x], {"^o": "Kernel", json_class: "Kernel"})

puts "-- the store --"
slot = QueueStore.for(ME)
check("nothing saved, nothing loaded", slot.load("k"), nil)
check("a save succeeds", slot.save("k", snap), true)
check("and loads back identical", slot.load("k") == snap, true)
check("only under the same key", slot.load("another label"), nil)
check("and only for the same person", QueueStore.for("mohi-kalantari").load("k"), nil)
slot.save("k2", snap.merge(rate: "1"))
check("one row per person, replaced", DB.row("SELECT count(*)::int AS n FROM saved_queues WHERE login = $1", [ME])["n"], 1)
check("the newest wins", slot.load("k2")[:rate], "1")
# Someone else's queue under my login -- which only a bug could write -- is not mine.
DB.exec("UPDATE saved_queues SET queue = $1 WHERE login = $2", [SnapshotCodec.dump(snap.merge(login: "mohi-kalantari")), ME])
check("a queue that names another login is refused", slot.load("k2"), nil)
DB.exec("UPDATE saved_queues SET queue = 'not json' WHERE login = $1", [ME])
check("an unreadable save is no save, not an error", slot.load("k2"), nil)
DB.exec("DELETE FROM saved_queues")

puts "-- a service with nothing in memory shows the saved queue at once --"
builds = 0
gate = Queue.new
make = lambda do |label: ""|
  QueueService.new(token: "x", scope: "repo:o/r", label: label, saved: QueueStore.for(ME)).tap do |svc|
    svc.define_singleton_method(:build) do
      builds += 1
      gate.pop
      {rows: [{key: "o/r##{builds}"}], login: ME, fetched_at: Time.now, rate: nil, error: nil, counts: {}, reviews_7d: nil}
    end
  end
end
first = make.call
gate << true
cold = first.snapshot
check("with nothing saved, the first load waits for a build", builds, 1)
check("and that build is saved", QueueStore.for(ME).load(first.send(:saved_key))[:rows], [{key: "o/r#1"}])

# A restart: a new service, nothing in memory. The saved queue is ten minutes
# old by now, as it would be after a deploy.
DB.exec("UPDATE saved_queues SET queue = $1 WHERE login = $2", [SnapshotCodec.dump(cold.merge(fetched_at: Time.now - 600)), ME])
second = make.call
reader = Thread.new { second.snapshot }
shown = reader.join(0.3) && reader.value
check("after a restart the page is served without waiting", !shown.nil?, true)
check("the saved queue", shown && shown[:rows], [{key: "o/r#1"}])
check("marked as being refreshed", second.refreshing?, true)
gate << true
check("the rebuild behind it finishes", wait_until { !second.refreshing? }, true)
check("the next load has the new queue", second.snapshot[:rows], [{key: "o/r#2"}])
check("which is saved in its turn", QueueStore.for(ME).load(second.send(:saved_key))[:rows], [{key: "o/r#2"}])

# Even a restored queue a minute old is rebuilt once behind the page: it was
# built by the code before the deploy, and never checked against this token.
DB.exec("UPDATE saved_queues SET queue = $1 WHERE login = $2",
        [SnapshotCodec.dump(second.snapshot.merge(fetched_at: Time.now - 60)), ME])
young = make.call
check("a young restored queue is shown at once", young.snapshot[:rows], [{key: "o/r#2"}])
check("and still rebuilt behind the page", young.refreshing?, true)
gate << true
wait_until { !young.refreshing? }
check("once", builds, 3)
check("and not again while it is fresh", (young.snapshot; sleep 0.05; young.refreshing? || builds != 3), false)

loads = 0
counting = QueueStore.for(ME)
counting.define_singleton_method(:load) { |key| loads += 1; super(key) }
third = QueueService.new(token: "x", scope: "repo:o/r", label: "", saved: counting)
third.define_singleton_method(:build) { raise "not wanted" }
5.times { third.snapshot rescue nil }
check("the database is asked once per service, not per page", loads, 1)

other_label = make.call(label: "clickhouse")
gate << true
other_label.snapshot
check("a queue saved for another label is not shown for this one", builds, 4)

# A failed rebuild keeps the rows it had but is not saved: a restart must not
# bring back an error that has long since passed.
# One slot per person: the clickhouse save above replaced the unlabelled one,
# so this service has nothing to restore and builds.
failing = make.call
gate << true
failing.snapshot
check("a queue saved for one label replaces the other's", builds, 5)
failing.instance_variable_set(:@snapshot, failing.snapshot.merge(fetched_at: Time.now - 600))
failing.define_singleton_method(:build) { raise "GitHub 502" }
failing.snapshot
wait_until { !failing.refreshing? }
check("a failed rebuild shows its error", failing.snapshot[:error].to_s.include?("502"), true)
check("but is not saved", QueueStore.for(ME).load(failing.send(:saved_key))[:error], nil)

puts "-- the key carries the shape of a row --"
# If this list changes, rows saved before the change would be restored with
# fields missing or wrong. Bump QueueService::SAVED_FORMAT, then update it.
ROW_FIELDS = %i[age age_color age_text_color author buckets changed chips churn ci ci_color draft key last_at
                last_what last_who my_action my_action_kind number quick read_est ready ref repo repo_full row_bg
                settled size_sub sort_key state state_bg state_color title url].freeze
now = Time.now
sample = {url: "u", title: "t", number: 1, repo: "r", owner: "o", author: "a", draft: false, ci: :pass, labels: [],
          buckets: [:review], mine: false, last: {at: now, who: "a", kind: "comment"}, my_last: nil,
          last_other: {at: now, who: "a", kind: "comment"}, i_acted: false, awaiting_review: true, approved: false,
          changed: 1, churn: 2}
check("a row has the fields format #{QueueService::SAVED_FORMAT} was saved with",
      QueueService.new(token: "x", scope: "s", label: "").send(:row, sample, ME).keys.sort, ROW_FIELDS)
check("and the format is in the key", first.send(:saved_key).start_with?("#{QueueService::SAVED_FORMAT}\n"), true)

puts "-- through the app: a deploy no longer means a wait --"
DB.exec("DELETE FROM saved_queues")
DB.exec("DELETE FROM user_settings")
app_builds = 0
QueueService.class_eval do
  define_method(:build) do
    app_builds += 1
    sleep 0.6                                # long enough to tell a wait from none
    rows = [{key: "o/r#7", repo: "r", repo_full: "o/r", number: 7, last_at: Time.now - 3600, buckets: [:review],
             settled: false, sort_key: [0, 0], draft: false, url: "u", title: "Saved across a restart", ref: "r #7",
             author: "a", state: "To review", state_bg: "x", state_color: "y", row_bg: "z", age_color: "a",
             age_text_color: "b", age: "1h", last_who: "a", last_what: "comment · 1h ago", my_action: "never",
             my_action_kind: nil, quick: false, churn: 1, changed: 1, read_est: "~1m", size_sub: "±1 · 1f",
             ci: "pass", ci_color: "c", chips: [], ready: false}]
    {rows: rows, counts: counts(rows), login: ME, fetched_at: Time.now, rate: 5000, error: nil,
     reviews_7d: {count: 0, complete: true}, merged: [], issues: [], issues_error: nil}
  end
end
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => ME} } }
include Rack::Test::Methods
def app = ReviewQueue.app
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/"
check("the very first load builds", app_builds, 1)
check("and shows the queue", last_response.body.include?("Saved across a restart"), true)
# What a deploy does to memory: every service gone.
REGISTRY.forget(ME)
DB.exec("UPDATE saved_queues SET queue = $1 WHERE login = $2",
        [SnapshotCodec.dump(SnapshotCodec.load(DB.row("SELECT queue FROM saved_queues WHERE login = $1", [ME])["queue"])
                              .merge(fetched_at: Time.now - 3 * 3600)), ME])
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
get "/"
took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
check("after it, the page does not wait for a build", took < 0.4, true)
check("it shows the saved queue", last_response.body.include?("Saved across a restart"), true)
check("says how old it is and that it is refreshing", last_response.body.include?("updated 3h ago · refreshing…"), true)
check("and comes back for the new one in seconds", last_response.body.include?('content="10"'), true)
check("while the rebuild runs behind it", wait_until { app_builds == 2 }, true)

puts "-- and the allowlist, not GitHub, decides who sees it --"
# Removed from the list with a session still open: before, the next page
# needed GitHub, and only a dead token stopped them. A saved queue does not
# ask GitHub first, so the list is checked on every request.
ReviewQueue.class_eval { alias_method :allowed_before_test?, :allowed?; define_method(:allowed?) { |_login| false } }
get "/"
check("a removed person is sent to sign in", [last_response.status, last_response.location], [302, "/login"])
check("with their session cleared", last_request.session["login"], nil)
check("nothing of the queue in the answer", last_response.body.include?("Saved across a restart"), false)
get "/login"
check("and the sign-in page does not bounce them back", last_response.status, 200)
ReviewQueue.class_eval { alias_method :allowed?, :allowed_before_test? }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
