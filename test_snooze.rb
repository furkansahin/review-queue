#!/usr/bin/env ruby
# Snooze list tests:  bundle exec ruby test_snooze.rb
require_relative "snooze"

NOW = Time.now
def row(key, last_ago_days) = {key: key, last_at: last_ago_days && (NOW - last_ago_days * 86_400), settled: false}

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-6s want=%s", ok ? "ok  " : "FAIL", name, got, want)
end

# --- a fresh snooze hides the row -------------------------------------------
r = row("o/r#1", 3)                       # last activity 3 days ago
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: NOW).sweep([r], now: NOW)
check("fresh snooze hides the row", s.hidden?(r), true)

# --- the snooze time completes ----------------------------------------------
s = Snooze.new({}).add("o/r#1", 86_400, now: NOW - 2 * 86_400).sweep([r], now: NOW)
check("row wakes when the time is complete", s.hidden?(r), false)

# --- new activity wakes the row (the important rule) ------------------------
snoozed_at = NOW - 3 * 86_400
new_r = row("o/r#1", 1)                   # activity 1 day ago, after the snooze
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: snoozed_at).sweep([new_r], now: NOW)
check("new activity wakes the row early", s.hidden?(new_r), false)

# --- old activity does NOT wake the row -------------------------------------
old_r = row("o/r#1", 10)                  # activity 10 days ago, before the snooze
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: snoozed_at).sweep([old_r], now: NOW)
check("older activity keeps the row hidden", s.hidden?(old_r), true)

# --- a row with no activity at all ------------------------------------------
none = row("o/r#9", nil)
s = Snooze.new({}).add("o/r#9", 7 * 86_400, now: NOW).sweep([none], now: NOW)
check("row with no last_at stays hidden", s.hidden?(none), true)

# --- the pull request leaves the queue --------------------------------------
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: NOW).sweep([], now: NOW)
check("entry is dropped when the PR leaves", s.count, 0)

# --- unsnooze ----------------------------------------------------------------
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: NOW).remove("o/r#1")
check("remove drops the entry", s.count, 0)

# --- the cookie cannot grow without a limit ---------------------------------
s = Snooze.new({})
40.times { |i| s.add("o/r##{i}", (i + 1) * 86_400, now: NOW) }
check("list is capped at MAX_ENTRIES", s.count, Snooze::MAX_ENTRIES)
kept = s.to_h.keys
check("cap keeps the newest snoozes", kept.include?("o/r#39"), true)
check("cap drops the oldest snoozes", kept.include?("o/r#0"), false)

# --- the store survives a JSON round trip, because it lives in a cookie ------
require "json"
s = Snooze.new({}).add("o/r#1", 7 * 86_400, now: NOW)
back = Snooze.new(JSON.parse(JSON.generate(s.to_h)))
check("survives JSON round trip (cookie storage)", back.hidden?(r), true)

# --- a snooze list is nobody else's to change -----------------------------
# Hash#to_h returns the same hash when it is already one, so building a Snooze
# from a hash used to share it: adding or sweeping reached back out and changed
# the caller's copy. The app never noticed, because each request builds one of
# these from a freshly deserialized cookie. It still cost a wrong answer about
# when a snooze ends, in a check that built two from one hash.
stored = Snooze.new({}).add("o/r#1", 600).to_h
Snooze.new(stored).sweep([])
check("sweeping a copy leaves the original alone", stored.key?("o/r#1"), true)
Snooze.new(stored).add("o/r#2", 600)
check("nor does adding to one", stored.size, 1)

live = Snooze.new({}).add("o/r#1", 600)
live.to_h.clear
check("and what to_h hands out cannot empty it", live.count, 1)
live.to_h["o/r#9"] = [1, 2]
check("nor add to it", live.count, 1)

# The pairs inside are replaced whole, never mutated, so a shallow copy is
# enough -- but say so, in case that ever stops being true.
first = Snooze.new({}).add("o/r#1", 600)
copy = Snooze.new(first.to_h)
copy.add("o/r#1", 99_999)
check("re-snoozing in a copy does not move the original's wake time",
      first.to_h["o/r#1"], Snooze.new(first.to_h).to_h["o/r#1"])

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
