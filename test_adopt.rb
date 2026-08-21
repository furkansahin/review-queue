#!/usr/bin/env ruby
# Resuming after a restart:  bundle exec ruby test_adopt.rb
#
# A deploy restarts the worker, which kills the process it spawned -- but not
# the review, which runs inside the box and keeps going. The job must be picked
# back up rather than marked failed.
ENV["DATABASE_URL"] ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "db"
require_relative "jobs"
require_relative "devbox"
require_relative "runner"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-26s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 26], want.inspect[0, 26])
end

DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
priv, pub = DevBox.generate_keypair
box = DB.row(<<~SQL, ["furkansahin", "10.0.0.5", "ubi", 22, Crypto.encrypt(priv), pub])
  INSERT INTO dev_boxes (login, host, ssh_user, port, private_key_enc, public_key)
  VALUES ($1,$2,$3,$4,$5,$6) RETURNING *
SQL
job = DB.row(<<~SQL, ["furkansahin", box["id"], "ubicloud/ubicloud", 77, "rq-x-77"])
  INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name, state, started_at)
  VALUES ($1,$2,$3,$4,$5,'running', now()) RETURNING *
SQL

# What the box says when asked for its copy of the run.
BOXSAYS = {text: "the review, half written\n"}
Runner.singleton_class.prepend(Module.new do
  def adopt(box_row, box_name)
    text = BOXSAYS[:text]
    mark = text.rindex(Runner::EXIT_MARK)
    {ok: true, finished: !mark.nil?,
     exit_code: mark ? text[(mark + Runner::EXIT_MARK.length)..].to_i : nil,
     output: mark ? text[0...mark] : text}
  end
  def run(_box_row, command, timeout: 120, stdin: nil)
    return {ok: true, output: "orphaned", exit_code: 0} if command.start_with?("status")
    {ok: true, output: "", exit_code: 0}
  end
  def run_many(box_row, commands, timeout: 120)
    commands.map { |c| run(box_row, c.is_a?(Array) ? c[0] : c) }
  end
end)

ENV["RQ_TRANSPORT"] = "bay"
load File.expand_path("worker.rb", __dir__) rescue nil

puts "-- a run still going in the box is kept, not failed --"
poll_running
row = DB.row("SELECT * FROM review_jobs WHERE id = $1", [job["id"]])
check("the job stays running", row["state"], "running")
check("and what the box has so far is stored", row["output"], "the review, half written\n")

puts "-- and when the box finishes it, the job finishes --"
BOXSAYS[:text] = "the whole review\n#{Runner::EXIT_MARK}0\n"
poll_running
row = DB.row("SELECT * FROM review_jobs WHERE id = $1", [job["id"]])
check("the job is done", row["state"], "done")
check("with the review, without the stamp", row["output"], "the whole review\n")
check("and no error", row["error"], nil)

puts "-- a run the box failed is a failure --"
DB.exec("UPDATE review_jobs SET state='running', output=NULL, error=NULL WHERE id=$1", [job["id"]])
BOXSAYS[:text] = "it broke\n#{Runner::EXIT_MARK}1\n"
poll_running
row = DB.row("SELECT * FROM review_jobs WHERE id = $1", [job["id"]])
check("the job failed", row["state"], "failed")
check("keeping what the box wrote", row["output"], "it broke\n")
check("and saying so", row["error"].to_s.include?("failed on the dev box"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
