#!/usr/bin/env ruby
# Live log tests:  bundle exec ruby test_stream.rb
require "fileutils"
require "tmpdir"
ROOT = Dir.mktmpdir("rq-stream")
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_BAY_ROOT"]             = ROOT
ENV["RQ_STREAM_SECONDS"]       = "3"
ENV["RQ_MAX_STREAMS"]          = "2"
FileUtils.mkdir_p([File.join(ROOT, "bin"), File.join(ROOT, "config")])
File.write(File.join(ROOT, "bin", "bay"), "#!/bin/sh\nexit 0\n")
File.chmod(0o755, File.join(ROOT, "bin", "bay"))
FileUtils.mkdir_p(File.join(ROOT, "bin", "cli-plugins"))
File.write(File.join(ROOT, "bin", "cli-plugins", "docker-compose"), "#!/bin/sh\nexit 0\n")
File.write(File.join(ROOT, "config", "bay.toml"), "x\n")
require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

WHO = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WHO[:login]} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: WHO[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: {count: 0, complete: true}}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app

DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
priv, pub = DevBox.generate_keypair
DB.exec(<<~SQL, ["furkansahin", "10.0.0.5", "ubi", 22, Crypto.encrypt(priv), pub])
  INSERT INTO dev_boxes (login, host, ssh_user, port, private_key_enc, public_key)
  VALUES ($1,$2,$3,$4,$5,$6)
SQL
box_id = DB.row("SELECT id FROM dev_boxes")["id"]
job = DB.row(<<~SQL, ["furkansahin", box_id, "ubicloud/ubicloud", 42, "rq-live-42"])
  INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name, state)
  VALUES ($1,$2,$3,$4,$5,'running') RETURNING *
SQL
JOB_ID = job["id"]

# The runner's own state directory, as a review would leave it.
dir = Runner.state_dir("furkansahin", "rq-live-42")
FileUtils.mkdir_p(dir)
File.write(File.join(dir, "state"), "reviewing\n")
File.write(File.join(dir, "pid"), "#{Process.pid}\n")
File.write(File.join(dir, "log"), "first line\n")

get "/auth/start"
st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

puts "-- a stream sends what is already there --"
# Rack::Test drains the body, so the stream must end for the request to return:
# mark it finished and read what came out.
File.write(File.join(dir, "state"), "done\n")
get "/sessions/stream?id=#{JOB_ID}&offset=0"
body = last_response.body
check("it answers as an event stream", last_response.headers["Content-Type"], "text/event-stream")
check("nginx is told not to buffer it", last_response.headers["X-Accel-Buffering"], "no")
check("the log arrives", body.include?("first line"), true)
check("as a log event", body.include?("event: log"), true)
check("and it says when the run ended", body.include?("event: end"), true)
check("with the final state", body.include?('"state":"done"'), true)

puts "-- an offset only sends what is new --"
File.write(File.join(dir, "log"), "first line\nsecond line\n")
get "/sessions/stream?id=#{JOB_ID}&offset=11"
check("the part already seen is not resent", last_response.body.include?("first line"), false)
check("the new part is", last_response.body.include?("second line"), true)

puts "-- an offset past the end resends the whole log --"
get "/sessions/stream?id=#{JOB_ID}&offset=999999"
check("rather than sending nothing for ever", last_response.body.include?("first line"), true)

puts "-- it is another user's log, so there is nothing to see --"
WHO[:login] = "mohi-kalantari"
o = Rack::Test::Session.new(Rack::MockSession.new(app))
o.get "/auth/start"; st2 = o.last_response.location[/state=([^&]+)/, 1]
o.get "/auth/callback?code=c&state=#{st2}"
o.get "/sessions/stream?id=#{JOB_ID}&offset=0"
check("a stranger gets no stream", o.last_response.status, 204)
check("and no bytes of it", o.last_response.body.include?("first line"), false)
WHO[:login] = "furkansahin"

puts "-- a job with no log falls back rather than hanging --"
job2 = DB.row(<<~SQL, ["furkansahin", box_id, "ubicloud/ubicloud", 43, "rq-live-43"])
  INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name, state)
  VALUES ($1,$2,$3,$4,$5,'running') RETURNING *
SQL
get "/sessions/stream?id=#{job2["id"]}&offset=0"
check("no log file means 204, not a stream", last_response.status, 204)
get "/sessions/stream?id=999999&offset=0"
check("nor for a job that does not exist", last_response.status, 204)

puts "-- polling still works, so the fallback is real --"
DB.exec("UPDATE review_jobs SET output = $1, state = 'running' WHERE id = $2", ["first line\nsecond line\n", JOB_ID])
get "/sessions/tail?id=#{JOB_ID}&offset=0"
check("the poll route still answers", JSON.parse(last_response.body)["chunk"].include?("second line"), true)

FileUtils.remove_entry(ROOT, true)
puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
