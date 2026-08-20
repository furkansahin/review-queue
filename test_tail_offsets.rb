#!/usr/bin/env ruby
# /sessions/tail byte offsets:  DATABASE_URL=... bundle exec ruby test_tail_offsets.rb
#
# The tail takes its slice in Postgres rather than reading the whole column and
# cutting it in Ruby, because it runs every two seconds for as long as a review
# is open. The offsets the browser sends are byte counts, and the column is
# text, so the two have to be made to agree -- these are the cases where a
# character-based slice would quietly corrupt the stream.
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]         = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]         = "furkansahin,someone-else"
ENV["RQ_GITHUB_CLIENT_ID"]       = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"]   = "csecret"
ENV["RQ_BASE_URL"]               = "http://example.com"
ENV["RQ_SESSION_SECRET"]         = "a" * 64
ENV["RQ_INSECURE_COOKIES"]       = "1"

require "rack/test"
require "json"
require_relative "app"

include Rack::Test::Methods
def app = ReviewQueue.freeze

$fails = 0
def check(name, got, want)
  ok = got == want
  $fails += 1 unless ok
  puts format("  %-4s  %-50s got=%-26s want=%s", ok ? "ok" : "FAIL", name,
              got.inspect[0, 26], want.inspect[0, 26])
end

DB.setup!
DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "box.example", "x", "ssh-rsa AAAA"])
bid = DB.row("SELECT id FROM dev_boxes")["id"]

# Accents and an emoji: 2- and 4-byte sequences, so byte offsets and character
# offsets disagree and any confusion between them is visible.
TEXT = "## Review\nnaïve reduce 🚀 raises on []\nsecond line café ✅\n"
DB.exec(<<~SQL, [bid, TEXT])
  INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name, state, output, phase)
  VALUES ('furkansahin', $1, 'ubicloud/ubicloud', 7, 'rq-ubicloud-7', 'running', $2, 'reviewing')
SQL
ID = DB.row("SELECT id FROM review_jobs")["id"]

env "rack.session", {"login" => "furkansahin", "token" => "t"}
def tail(offset)
  get "/sessions/tail?id=#{ID}&offset=#{offset}"
  JSON.parse(last_response.body)
end

check("the text is longer in bytes than in characters", TEXT.bytesize > TEXT.length, true)

d = tail(0)
check("length is a byte count", d["length"], TEXT.bytesize)
check("the whole log round-trips", d["chunk"], TEXT)
check("a running job is not done", d["done"], false)

cut = "## Review\nnaïve reduce 🚀".bytesize
d = tail(cut)
check("resumes at exactly the byte offset", d["chunk"], TEXT.byteslice(cut..))
check("the emoji before it is not re-sent", d["chunk"].start_with?(" raises"), true)
check("what came back is valid UTF-8", d["chunk"].valid_encoding?, true)

d = tail(TEXT.bytesize)
check("caught up sends no bytes", d["chunk"], "")
check("but still reports the length", d["length"], TEXT.bytesize)

# The browser only ever sends a boundary it was given, but a hand-typed offset
# must not become a 500.
get "/sessions/tail?id=#{ID}&offset=#{cut - 2}"
check("an offset inside a character still answers 200", last_response.status, 200)
check("and returns usable JSON", JSON.parse(last_response.body)["chunk"].valid_encoding?, true)

# An offset past the end means the log was replaced by a shorter one. Sending
# nothing leaves the client frozen on text that is no longer there, so the whole
# log goes again from the start.
get "/sessions/tail?id=#{ID}&offset=99999999"
d = JSON.parse(last_response.body)
check("an offset past the end answers 200", last_response.status, 200)
check("and resends the log from the start", d["chunk"], TEXT)
check("with the new, shorter length", d["length"], TEXT.bytesize)

DB.exec("UPDATE review_jobs SET output = $2 WHERE id = $1", [ID, "short\n"])
d = tail(TEXT.bytesize)                    # the client still holds the old offset
check("a replaced, shorter log is resent whole", d["chunk"], "short\n")
check("and the client is given the new length", d["length"], 6)
DB.exec("UPDATE review_jobs SET output = $2 WHERE id = $1", [ID, TEXT])

get "/sessions/tail?id=#{ID}&offset=-5"
check("a negative offset answers 200", last_response.status, 200)
check("and sends from the start", JSON.parse(last_response.body)["chunk"], TEXT)

get "/sessions/tail?id=#{ID}&offset=notanumber"
check("a non-numeric offset answers 200", last_response.status, 200)
check("and sends from the start", JSON.parse(last_response.body)["chunk"], TEXT)

DB.exec("UPDATE review_jobs SET output = NULL WHERE id = $1", [ID])
d = tail(0)
check("a job with no output reads as empty", d["chunk"], "")
check("with zero length", d["length"], 0)

DB.exec("UPDATE review_jobs SET state = 'done', output = $2 WHERE id = $1", [ID, TEXT])
check("a finished job reports done, so the poller stops", tail(0)["done"], true)

# The whole endpoint stays scoped to the owner.
env "rack.session", {"login" => "someone-else", "token" => "t"}
get "/sessions/tail?id=#{ID}&offset=0"
check("another user cannot tail it", last_response.body.include?("not found"), true)

puts($fails.zero? ? "\nALL PASS" : "\n#{$fails} FAILURE(S)")
exit($fails.zero? ? 0 : 1)
