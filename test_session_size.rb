#!/usr/bin/env ruby
# Session cookie tests:  bundle exec ruby test_session_size.rb
#
# The session is a 4 KB cookie. Roda refuses to write one at or above that,
# which surfaced as "Something went wrong" on every page, and the only way back
# was clearing cookies -- a user cannot do that from inside the app, and
# clearing them loses the watch label and the snooze list too.
#
# So the things that go in it are bounded, and this holds the bound.
require "roda"
require "rack/test"
require_relative "snooze"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end

LIMIT = 4096
SECRET = "a" * 64
APP = Class.new(Roda) do
  plugin :sessions, secret: SECRET, key: "_review_queue"
  route { |r| r.get("set") { session.replace($payload); "ok" } }
end

def cookie_bytes(payload)
  $payload = payload
  s = Rack::Test::Session.new(Rack::MockSession.new(APP))
  s.get "/set"
  (s.last_response.headers["set-cookie"] || s.last_response.headers["Set-Cookie"]).to_s.bytesize
rescue StandardError => e
  e.class.to_s
end

# What a heavy but ordinary session holds: signed in, a watch label, a full
# snooze list, and one of every flash at its bound.
FLASH_MAX = 200
def heavy(flashes: 4, snoozes: Snooze::MAX_ENTRIES, flash_len: FLASH_MAX)
  base = {
    "login" => "a-long-github-username", "token" => "gho_#{"x" * 40}",
    "label" => "a-fairly-long-watch-label", "authed_at" => Time.now.to_i,
    "snoozed" => (1..snoozes).to_h { |i|
      ["ubicloud/ubicloud##{6000 + i}", [Time.now.to_i + 604_800, Time.now.to_i]]
    }
  }
  %w[sessions_error sessions_notice baybox_error review_error].first(flashes).each_with_index do |k, i|
    base[k] = "#{"x" * flash_len}#{i}"
  end
  base
end

puts "-- the worst ordinary session still fits --"
worst = cookie_bytes(heavy)
check("it is a size, not an exception", worst.is_a?(Integer), true)
check("and it is under the limit", worst.is_a?(Integer) && worst < LIMIT, true)
puts "        #{worst} bytes of #{LIMIT}"
check("with room to spare", worst.is_a?(Integer) && worst < LIMIT * 0.8, true)

puts "-- the snooze list cannot grow without bound --"
s = Snooze.new({})
200.times { |i| s.add("ubicloud/ubicloud##{6000 + i}", 604_800) }
check("it stops at the cap", s.to_h.size, Snooze::MAX_ENTRIES)
check("and the cap leaves room", cookie_bytes(heavy(flashes: 0)).is_a?(Integer), true)

puts "-- an unbounded flash is what broke it --"
# The prepare output ran past a thousand bytes and went straight into the
# session. Two of those, with a full snooze list, is over the limit.
check("1200 bytes of output would not fit",
      cookie_bytes(heavy(flashes: 2, flash_len: 1200)), "Roda::RodaPlugins::Sessions::CookieTooLarge")
check("but the same thing bounded does",
      cookie_bytes(heavy(flashes: 2, flash_len: FLASH_MAX)).is_a?(Integer), true)

puts "-- and the bound is enforced in the app, not by hoping --"
src = File.read(File.join(__dir__, "app.rb"))
# Clearing one (= nil) is fine; it is setting text that has to be bounded.
# Done a line at a time, because a lookahead after \s* just backtracks onto
# the space and passes -- which it did, twice, while writing this.
FLASH_KEYS = /session\["(?:sessions_error|sessions_notice|baybox_error|baybox_notice|review_error)"\]\s*=/
unbounded = src.lines.select { |l| l.match?(FLASH_KEYS) && !l.match?(/=\s*nil\s*$/) }
check("every flash that sets text goes through one helper", unbounded, [])
check("which truncates", src.include?("FLASH_MAX"), true)
check("and the prepare output is stored instead",
      src.include?("UPDATE bayboxes SET last_error = $1"), true)

puts "-- a session that is already too big recovers itself --"
# Anyone who hit this before the bound was added still had the oversized
# cookie. The queue rewrites the session on every load, so every load failed,
# the cookie never changed, and the only way out was clearing cookies -- which
# the site cannot ask for, and which costs the sign-in and the snooze list.
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:5432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin"
ENV["RQ_GITHUB_CLIENT_ID"]     = "c"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "s"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
require_relative "app"
ReviewQueue.route do |r|
  r.get("wedge") do
    session["login"] = "furkansahin"
    session["baybox_error"] = "x" * 3000
    session["snoozed"] = (1..80).to_h { |i| ["ubicloud/ubicloud##{i}", [Time.now.to_i + 1, 2]] }
    "set"
  end
  r.get("after") { "login=#{session["login"].inspect} snoozed=#{session["snoozed"].to_h.size}" }
end
web = Rack::Test::Session.new(Rack::MockSession.new(ReviewQueue.app))
web.get "/wedge"
check("an oversized write redirects rather than failing", web.last_response.status, 302)
web.get "/after"
check("and the next page loads", web.last_response.status, 200)
check("the sign-in is kept", web.last_response.body.include?('login="furkansahin"'), true)
check("the snooze list is what was shed", web.last_response.body.include?("snoozed=0"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
