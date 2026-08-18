#!/usr/bin/env ruby
# Per-user watch label tests:  bundle exec ruby test_watch_label.rb
require_relative "queue_service"
require_relative "auth"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-34s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end

keys = ->(svc) { svc.buckets.map { |b| b[:key] } }

# --- the bucket only exists when the user watches something -----------------
check("no label -> no label bucket", keys.(QueueService.new(token: "t", scope: "s", label: "")),
      [:review, :mention, :mine])
check("label -> label bucket, in position", keys.(QueueService.new(token: "t", scope: "s", label: "clickhouse")),
      [:review, :mention, :label, :mine])
check("nil label behaves as empty", keys.(QueueService.new(token: "t", scope: "s", label: nil)),
      [:review, :mention, :mine])
check("whitespace-only label is empty",
      keys.(QueueService.new(token: "t", scope: "s", label: "   ")), [:review, :mention, :mine])

# --- the label is interpolated into a quoted search term --------------------
check("quotes and backslashes are removed",
      QueueService.clean_label(%q{x" OR is:merged \\}), "x OR is:merged")
check("length is capped", QueueService.clean_label("a" * 200).length, 64)

# --- the registry must not serve one user's label to another ---------------
reg = ServiceRegistry.new(idle_ttl: 3600, max_users: 10, scope: "repo:o/r")
a = reg.for("furkansahin", "tok_a", label: "clickhouse")
b = reg.for("mohi-kalantari", "tok_b", label: "")
check("user A keeps their own label", a.label, "clickhouse")
check("user B gets no label", b.label, "")
check("user B has no label bucket", keys.(b), [:review, :mention, :mine])
check("services are separate objects", a.equal?(b), false)

# --- changing your label rebuilds the service, so the cache cannot go stale -
a2 = reg.for("furkansahin", "tok_a", label: "clickhouse")
check("same label reuses the service", a.equal?(a2), true)
a3 = reg.for("furkansahin", "tok_a", label: "postgres")
check("new label rebuilds the service", a.equal?(a3), false)
check("rebuilt service uses the new label", a3.label, "postgres")
check("changing label leaks no extra entry", reg.size, 2)
a4 = reg.for("furkansahin", "tok_a", label: "  postgres  ")
check("label is compared after cleaning", a3.equal?(a4), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
