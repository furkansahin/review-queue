#!/usr/bin/env ruby
# The review worker. Runs as its own Dokku process (see Procfile).
#
# Each tick does two independent things, so a restart never loses work:
#   1. start queued jobs   — ssh to the user's dev box, rq-review review ...
#   2. poll running jobs   — rq-review status, then result when it is finished
#
# rq-review detaches on the box, so neither step holds a connection open for
# the minutes a review takes.
require_relative "db"
require_relative "jobs"
require_relative "devbox"

TICK = Integer(ENV.fetch("RQ_WORKER_TICK", "10"))

def log(message)
  $stdout.puts("[worker] #{Time.now.utc.iso8601} #{message}")
  $stdout.flush
end

def start_queued
  while (job = Jobs.claim)
    begin
      start_one(job)
    rescue StandardError => e
      Jobs.finish(job["id"], "failed", error: "#{e.class}: #{e.message}")
      log("error starting job #{job["id"]}: #{e.class}: #{e.message}")
    end
  end
end

def start_one(job)
  box = Jobs.dev_box(job)
  return Jobs.finish(job["id"], "failed", error: "the dev box was removed") unless box

  command = DevBox.review_command(repo: job["repo"], pr_number: job["pr_number"], box: job["box_name"])
  res = DevBox.run(box, command)
  if res[:ok]
    log("started #{job["box_name"]} for #{job["login"]}")
  else
    Jobs.finish(job["id"], "failed", output: res[:output], error: res[:error] || "could not start the review")
    log("could not start #{job["box_name"]}: #{res[:error] || res[:output].to_s[0, 200]}")
  end
end

def poll_running
  Jobs.running.each do |job|
    box = Jobs.dev_box(job)
    unless box
      Jobs.finish(job["id"], "failed", error: "the dev box was removed")
      next
    end

    status = DevBox.run(box, "status #{job["box_name"]}")
    state = status[:output].to_s.strip

    # A box that cannot be reached is not a failure yet: it may be rebooting.
    # The staleness check below is what eventually gives up.
    unless status[:ok]
      Jobs.finish(job["id"], "failed", error: "dev box unreachable for too long") if Jobs.stale?(job)
      next
    end

    case state
    when "done", "failed"
      result = DevBox.run(box, "result #{job["box_name"]}")
      Jobs.finish(job["id"], state == "done" ? "done" : "failed",
        output: result[:output],
        error: state == "failed" ? "the review command failed on the dev box" : nil)
      log("#{job["box_name"]} finished: #{state}")
    when "running"
      # Store what the box has printed so far, so the sessions page can show
      # progress instead of a spinner for the five minutes a box takes to build.
      partial = DevBox.run(box, "result #{job["box_name"]}")
      Jobs.progress(job["id"], partial[:output]) if partial[:ok]
    else
      Jobs.finish(job["id"], "failed", output: nil, error: "gave up after #{Jobs::STALE_AFTER}s") if Jobs.stale?(job)
    end
  rescue StandardError => e
    log("error polling job #{job["id"]}: #{e.class}: #{e.message}")
  end
end

if $PROGRAM_NAME == __FILE__
  require "time"
  log("starting, tick #{TICK}s")
  DB.setup!
  loop do
    begin
      start_queued
      poll_running
    rescue StandardError => e
      log("tick failed: #{e.class}: #{e.message}")
    end
    sleep TICK
  end
end
