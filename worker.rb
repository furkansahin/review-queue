#!/usr/bin/env ruby
# The review worker. Runs as its own Dokku process (see Procfile).
#
# Each tick does two independent things, so a restart never loses work:
#   1. start queued jobs   — bay up + bay run, against the user's own machine
#   2. poll running jobs   — status, then result when it is finished
#   3. adopt orphans       — a review this host started but lost, which is
#                            still running in the box
#
# The review runs detached here, so neither step waits out the minutes a review
# takes. bay drives the user's Docker over ssh; the containers are still theirs.
require_relative "db"
require_relative "jobs"
require_relative "devbox"
require_relative "runner"

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

  # Runner validates each field before it reaches a command line, and answers
  # with the reason if one is wrong.
  res = Runner.run(box, "review #{job["repo"]} #{job["pr_number"]} #{job["box_name"]}")
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

    # Both answers over one connection. Every branch below that does anything
    # wants the output, so asking for it up front costs a channel and saves a
    # whole connection -- handshake, key exchange and a 4096-bit signature --
    # for every running job on every tick.
    status, result = Runner.run_many(box, ["status #{job["box_name"]}",
                                        "result #{job["box_name"]}"])
    state = status[:output].to_s.strip

    # A box that cannot be reached is not a failure yet: it may be rebooting.
    # The staleness check below is what eventually gives up.
    unless status[:ok]
      Jobs.finish(job["id"], "failed", error: "dev box unreachable for too long") if Jobs.stale?(job)
      next
    end

    case state
    when "orphaned"
      # This host lost track of the run -- a deploy, a restart. The box kept
      # going (a docker exec outlives its client), so take it back rather than
      # calling a review failed that is still being written.
      taken = Runner.adopt(box, job["box_name"])
      unless taken[:ok]
        log("could not adopt #{job["box_name"]}: #{taken[:error]}")
        Jobs.finish(job["id"], "failed", error: "lost the run and could not reach the box") if Jobs.stale?(job)
        next
      end
      if taken[:finished]
        Jobs.finish(job["id"], taken[:exit_code].to_i.zero? ? "done" : "failed",
          output: taken[:output],
          error: taken[:exit_code].to_i.zero? ? nil : "the run failed on the dev box")
        log("adopted #{job["box_name"]} and it was finished: #{taken[:exit_code]}")
      else
        Jobs.progress(job["id"], taken[:output], "reviewing")
        log("adopted #{job["box_name"]}, still running in the box")
      end
    when "done", "failed"
      # A failed build leaves no review text, so fall back to bay's log for the
      # error message only -- it is never shown as review output.
      detail = nil
      if state == "failed"
        b = Runner.run(box, "build #{job["box_name"]}")
        detail = b[:output].to_s.lines.last(12).join.strip
      end
      # Only write output when the fetch actually succeeded. Runner.run's rescue
      # path returns output:"", so a single dropped connection here used to
      # overwrite a finished review with nothing -- and jobs.rb only rescans
      # state='running', so it was gone for good.
      unless result[:ok]
        log("could not collect #{job["box_name"]}: #{result[:error]} -- leaving it running to retry")
        Jobs.finish(job["id"], "failed", error: "could not collect the review: #{result[:error]}") if Jobs.stale?(job)
        next
      end
      Jobs.finish(job["id"], state == "done" ? "done" : "failed",
        output: result[:output],
        error: state == "failed" ? "the run failed on the dev box\n#{detail}" : nil)
      log("#{job["box_name"]} finished: #{state}")
    when "building", "reviewing", "running"
      # result is claude's output only; bay's build noise stays in build.log and
      # is never streamed to the page. It came back with the status above.
      Jobs.progress(job["id"], result[:output], state) if result[:ok]
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
    # Claude writes in bursts; poll it closely, and idle back while a box builds.
    reviewing = begin
      DB.row("SELECT 1 FROM review_jobs WHERE state = 'running' AND phase = 'reviewing' LIMIT 1")
    rescue StandardError
      nil
    end
    sleep(reviewing ? [TICK, 3].min : TICK)
  end
end
