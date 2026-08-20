#!/usr/bin/env ruby
# Page weight:  DATABASE_URL=... bundle exec ruby test_page_weight.rb
#
# rq-review caps a review at 200 KB and the sessions page lists 50 jobs, so
# printing every one built a 10 MB page and the queue page pulled all 10 MB out
# of Postgres to render a state word. These assert the pages stay bounded --
# and, just as importantly, that every review is still reachable.
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

# No dev box in a test, and the box list is not what is being measured.
DevBox.singleton_class.prepend(Module.new do
  def run_many(_box, commands, **) = commands.map { {ok: true, output: "", exit_code: 0} }
end)

include Rack::Test::Methods
def app = ReviewQueue.freeze

$fails = 0
def check(name, got, want)
  ok = got == want
  $fails += 1 unless ok
  puts format("  %-4s  %-52s got=%-20s want=%s", ok ? "ok" : "FAIL", name,
              got.inspect[0, 20], want.inspect[0, 20])
end

DB.setup!
DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
        ["furkansahin", "box.example", "x", "ssh-rsa AAAA"])
bid = DB.row("SELECT id FROM dev_boxes")["id"]

# 50 finished reviews at the size rq-review actually caps them to.
JOBS = 50
CAP = 200_000
ids = []
JOBS.times do |i|
  body = "## Finding #{i}\n" + ("the reduce raises on an empty list\n" * 5000)
  DB.exec(<<~SQL, [bid, 6000 + i, "rq-ubicloud-#{6000 + i}", body[0, CAP]])
    INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name, state, output, finished_at)
    VALUES ('furkansahin', $1, 'ubicloud/ubicloud', $2, $3, 'done', $4, now())
  SQL
  ids << DB.row("SELECT id FROM review_jobs ORDER BY id DESC LIMIT 1")["id"]
end
stored = DB.row("SELECT sum(octet_length(output))::bigint s FROM review_jobs")["s"].to_i
puts "  #{JOBS} finished reviews stored = #{(stored / 1_048_576.0).round(1)} MB of text"

env "rack.session", {"login" => "furkansahin", "token" => "t"}

get "/sessions"
body = last_response.body
check("the sessions page renders", last_response.status, 200)
check("it is far smaller than everything stored", body.bytesize < stored / 4, true)
check("and is bounded, not proportional to history", body.bytesize < 2_000_000, true)
check("every job still has a card", JOBS.times.all? { |i| body.include?("rq-ubicloud-#{6000 + i}") }, true)

# The newest review is the one you just ran, so it is printed with the page.
newest = ids.last
check("the newest review is printed inline", body.include?("## Finding #{JOBS - 1}"), true)
# The oldest is not, but it is offered.
check("an older one is not printed", body.include?("## Finding 0\n"), false)
check("it is offered as a panel that loads", body.include?(%(data-review="#{ids.first}")), true)
check("with a plain link for a browser without scripting",
      body.include?("/sessions/review?id=#{ids.first}"), true)

# ...and that link really produces the review.
get "/sessions/review?id=#{ids.first}"
check("the link renders the review", last_response.body.include?("## Finding 0"), true)
get "/sessions/review?format=json&id=#{ids.first}"
loaded = JSON.parse(last_response.body)
check("and the script gets the same text as JSON", loaded["review"].include?("## Finding 0"), true)
check("marked as found", loaded["found"], true)

# An old single-stream log is still split on the far side of the lazy load.
mixed = (["docker build noise"] * 500).join("\n") + "\n== review\n## Review summary\nthe actual finding"
DB.exec("UPDATE review_jobs SET output = $1 WHERE id = $2", [mixed, ids.first])
get "/sessions/review?format=json&id=#{ids.first}"
loaded = JSON.parse(last_response.body)
check("a mixed log is still split", loaded["review"].start_with?("## Review summary"), true)
check("and its build noise is kept apart", loaded["noise"].to_s.include?("docker build noise"), true)

# Scoping.
env "rack.session", {"login" => "someone-else", "token" => "t"}
get "/sessions/review?format=json&id=#{ids.first}"
check("another user cannot read the review", JSON.parse(last_response.body)["found"], false)
get "/sessions/review?id=999999999"
check("a missing id is not a 500", last_response.status, 200)
get "/sessions/review?id=notanumber"
check("a non-numeric id is not a 500", last_response.status, 200)

# The queue page shows no review text at all, so it must not fetch any.
env "rack.session", {"login" => "furkansahin", "token" => "t"}
map = Jobs.by_key("furkansahin")
check("by_key still keys on owner/name#number", map.key?("ubicloud/ubicloud#6000"), true)
check("and carries the state the row shows", map["ubicloud/ubicloud#6000"]["state"], "done")
check("without carrying any review text",
      map.values.any? { |j| j.key?("output") }, false)

# A torn-down job leaves the map, so its row offers Review again.
DB.exec("UPDATE review_jobs SET torn_down_at = now() WHERE id = $1", [ids.first])
check("a torn-down job drops out of the map",
      Jobs.by_key("furkansahin").key?("ubicloud/ubicloud#6000"), false)

puts($fails.zero? ? "\nALL PASS" : "\n#{$fails} FAILURE(S)")
exit($fails.zero? ? 0 : 1)
