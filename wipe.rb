require_relative "db"
require_relative "jobs"

# Every box a person has, torn down in one go from the sessions page: boxes
# outlive their reviews and each keeps its disk, so they pile up by the dozen,
# and one button beats twenty.
#
# The page only asks. The worker does it, one box a tick, so the minutes twenty
# teardowns take never hold a request open, the other jobs keep being polled
# in between, and a restart picks up where it stopped. What is torn down is
# what the box had when the worker first looked: a review started after the
# button was pressed is left alone. Last, what older boxes left in Docker
# without bay knowing is cleared too (Runner.sweep).
module Wipe
  module_function

  def request(login)
    DB.exec(<<~SQL, [login])
      UPDATE bayboxes
      SET wipe_requested_at = now(), wipe_todo = NULL, wipe_done = 0, wipe_failed = NULL, wipe_note = NULL
      WHERE login = $1
    SQL
  end

  # {running:, left:, done:, note:} for the sessions page; nil with no baybox.
  def status(login)
    box = DB.row("SELECT wipe_requested_at, wipe_todo, wipe_done, wipe_note FROM bayboxes WHERE login = $1", [login])
    return nil unless box
    {running: !box["wipe_requested_at"].nil?, left: box["wipe_todo"] && box["wipe_todo"].split("\n").size,
     done: box["wipe_done"].to_i, note: box["wipe_note"]}
  end

  def names(list_output) = list_output.to_s.lines.map { |l| l.split("\t").first.to_s.strip }.reject(&:empty?)

  # One box for each person who asked. runner answers list, teardown and
  # forget_box_list the way Runner does.
  def tick(runner:, log: ->(_) {})
    DB.rows("SELECT * FROM bayboxes WHERE wipe_requested_at IS NOT NULL").each do |box|
      step(box, runner, log)
    rescue StandardError => e
      log.call("wipe: #{box["login"]}: #{e.class}: #{e.message[0, 200]}")
    end
  end

  def step(box, runner, log)
    login = box["login"]
    if box["wipe_todo"].nil?
      res = runner.list(box)
      unless res[:ok]
        return finish(box, "Could not tear down your boxes: the baybox could not be listed " \
                           "(#{(res[:error] || res[:output]).to_s.strip.lines.last.to_s.strip[0, 200]}).")
      end
      todo = names(res[:output])
      DB.exec("UPDATE bayboxes SET wipe_todo = $1 WHERE id = $2", [todo.join("\n"), box["id"]])
      log.call("wipe: #{login}: #{todo.size} boxes to tear down")
      box = box.merge("wipe_todo" => todo.join("\n"))
    end

    todo = box["wipe_todo"].split("\n")
    if todo.empty?
      failed = box["wipe_failed"].to_s.lines.map(&:strip).reject(&:empty?)
      done = box["wipe_done"].to_i
      note = if failed.empty?
               {0 => "There were no boxes to tear down.", 1 => "Tore down your one box."}.fetch(done, "Tore down all #{done} boxes.")
             else
               "Tore down #{done} of #{done + failed.size} boxes. These would not go: #{failed.join("; ")[0, 600]}"
             end
      return finish(box, "#{note}#{sweep(box, runner, log)}")
    end

    name, *rest = todo
    res = runner.teardown(box, name)
    runner.forget_box_list(box)
    if res[:ok]
      Jobs.mark_torn_down(login, name)
      DB.exec("UPDATE bayboxes SET wipe_todo = $1, wipe_done = wipe_done + 1 WHERE id = $2", [rest.join("\n"), box["id"]])
      log.call("wipe: #{login}: tore down #{name}, #{rest.size} left")
    else
      why = (res[:error] || res[:output]).to_s.strip.lines.last.to_s.strip[0, 200]
      DB.exec("UPDATE bayboxes SET wipe_todo = $1, wipe_failed = concat(wipe_failed, $2::text) WHERE id = $3",
              [rest.join("\n"), "#{name}: #{why}\n", box["id"]])
      log.call("wipe: #{login}: could not tear down #{name}: #{why}")
    end
  end

  # Then what older boxes left in Docker that bay no longer lists (see
  # Runner.sweep), sparing whatever is still listed or still has a job: a
  # review started since the button. What to add to the note, if anything.
  def sweep(box, runner, log)
    listed = runner.list(box)
    return " Could not look for what older boxes left behind: the baybox could not be listed." unless listed[:ok]
    live = DB.rows("SELECT box_name FROM review_jobs WHERE login = $1 AND state IN ('queued', 'running')",
                   [box["login"]]).map { |r| r["box_name"] }
    res = runner.sweep(box, keep: names(listed[:output]) + live)
    if !res[:ok]
      why = (res[:error] || res[:output]).to_s.strip.lines.last.to_s.strip[0, 200]
      log.call("wipe: #{box["login"]}: sweep failed: #{why}")
      " Could not clear what older boxes left behind: #{why}"
    elsif res[:boxes].to_a.any?
      log.call("wipe: #{box["login"]}: cleared leftovers of #{res[:boxes].join(", ")}")
      " Also cleared what #{res[:boxes].size == 1 ? "an older box" : "#{res[:boxes].size} older boxes"} " \
        "left behind in Docker: #{res[:boxes].join(", ")}."
    else
      ""
    end
  end

  def finish(box, note)
    DB.exec("UPDATE bayboxes SET wipe_requested_at = NULL, wipe_todo = NULL, wipe_note = $1 WHERE id = $2",
            [note, box["id"]])
  end

  # The last result has been shown; the page does not repeat it.
  def seen(login) = DB.exec("UPDATE bayboxes SET wipe_note = NULL WHERE login = $1 AND wipe_requested_at IS NULL", [login])
end
