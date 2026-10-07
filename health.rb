require "net/http"
require "uri"
require "time"
require "date"
require_relative "db"
require_relative "crypto"

# What is broken, or about to be, in what each person relies on while they
# are not looking: their two GitHub tokens, their box, the morning reviews,
# the learning of their review voice. The worker checks the tokens and the
# box every few hours and keeps the answers; the rest is already written down
# by the parts that run. The queue page shows whatever needs the person, on
# one line each, and nothing when all is well.
module Health
  CHECK_EVERY = 6 * 3600
  # A token expiring within this many days is worth a line on the page. Two
  # weeks, since a new fine-grained token for an organization may wait on an
  # admin's approval before it works.
  WARN_DAYS = 14

  module_function

  # --- the worker's part ------------------------------------------------------

  # One token, asked of GitHub: [state, expires_at]. state is "ok" or
  # "refused"; nil when GitHub could not be reached, which says nothing
  # about the token. /rate_limit costs nothing against the limit, and every
  # answer carries the token's expiry.
  def check_token(token)
    uri = URI("https://api.github.com/rate_limit")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    req["User-Agent"] = "leeghwater"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |h| h.request(req) }
    return ["refused", nil] if res.code == "401"
    return [nil, nil] unless res.is_a?(Net::HTTPSuccess)
    expires = res["github-authentication-token-expiration"]
    ["ok", expires && Time.parse(expires)]
  rescue StandardError
    [nil, nil]
  end

  def decrypt(enc)
    enc.to_s.empty? ? nil : Crypto.decrypt(enc)
  rescue Crypto::Error
    nil
  end

  # Both tokens and the box, for every baybox not checked in CHECK_EVERY.
  # check_box is Runner.check, passed in so this needs no ssh of its own.
  def tick(check_box:, log: ->(_) {})
    DB.rows(<<~SQL, [CHECK_EVERY]).each do |box|
      UPDATE bayboxes SET health_checked_at = now()
      WHERE id IN (SELECT id FROM bayboxes
                   WHERE health_checked_at IS NULL OR health_checked_at < now() - $1::int * interval '1 second'
                   LIMIT 10)
      RETURNING *
    SQL
      %w[read write].each do |which|
        col = which == "read" ? "github_token_enc" : "github_write_token_enc"
        token = decrypt(box[col])
        state, expires = token ? check_token(token) : ["missing", nil]
        next if state.nil?   # GitHub unreachable: keep what was known
        DB.exec("UPDATE bayboxes SET #{which}_token_state = $1, #{which}_token_expires_at = $2 WHERE id = $3",
                [state, expires, box["id"]])
      end
      res = check_box.call(box)
      if res[:ok]
        DB.exec("UPDATE bayboxes SET last_ok_at = now(), last_error = NULL WHERE id = $1", [box["id"]])
      else
        DB.exec("UPDATE bayboxes SET last_error = $1 WHERE id = $2",
                [(res[:error] || res[:output]).to_s.strip[0, 500], box["id"]])
      end
      log.call("health #{box["login"]}: box #{res[:ok] ? "reachable" : "unreachable"}")
    rescue StandardError => e
      log.call("health: could not check #{box["login"]}: #{e.class}: #{e.message[0, 200]}")
    end
  end

  # --- what the page shows ----------------------------------------------------

  def days_left(at, now) = ((at - now) / 86_400.0).floor

  def when_left(at, now)
    n = days_left(at, now)
    case n
    when ..0 then "today"
    when 1 then "tomorrow"
    else "in #{n} days"
    end
  end

  # Each problem as {level: :error | :warn, text:, href:}, worst first.
  # snap is the queue being shown, for what only it knows.
  def problems(login, snap: nil, now: Time.now)
    out = []
    if snap && snap[:decisions_error]
      out << {level: :warn, text: "Could not read approvals from GitHub this time, so Ready to merge may be missing " \
                                  "(#{snap[:decisions_error].to_s[0, 120]}). It is asked again on the next refresh.",
              href: nil}
    end
    box = DB.row("SELECT * FROM bayboxes WHERE login = $1", [login])
    if box
      {"read" => ["github_token_enc", "read token", "reviews, mornings and learning your review voice"],
       "write" => ["github_write_token_enc", "write token", "drafting reviews, opening and pushing pull requests, and E2E"]}
        .each do |which, (col, name, uses)|
        next if box[col].to_s.empty?
        state = box["#{which}_token_state"]
        expires = box["#{which}_token_expires_at"]
        if state == "refused"
          out << {level: :error, text: "GitHub refuses your #{name}, so #{uses} have stopped. Add a new one on the Baybox page.", href: "/baybox"}
        elsif expires && expires <= now
          out << {level: :error, text: "Your #{name} expired #{expires.utc.strftime("%b %-d")}, so #{uses} have stopped. Add a new one on the Baybox page.", href: "/baybox"}
        elsif expires && expires - now < WARN_DAYS * 86_400
          out << {level: :warn, text: "Your #{name} expires #{when_left(expires, now)} (#{expires.utc.strftime("%b %-d")}): " \
                                      "renew it, and paste the new one on the Baybox page, before #{uses} stop.", href: "/baybox"}
        end
      end
      if box["last_error"].to_s.strip != "" && box["health_checked_at"]
        out << {level: :error, text: "Your box could not be reached at the last check: #{box["last_error"].to_s.lines.last.to_s.strip[0, 160]}",
                href: "/baybox"}
      end
    end
    settings = DB.row("SELECT prereview_on, prereview_last_on, prereview_note, voice_error, voice_error_at " \
                      "FROM user_settings WHERE login = $1", [login])
    if settings
      note = settings["prereview_note"].to_s
      last_on = settings["prereview_last_on"]
      if settings["prereview_on"] && note.include?("not prepared:") && last_on && (now.to_date - last_on).to_i <= 3
        out << {level: :error, text: "This morning's reviews were not started: #{note.split("not prepared: ", 2).last.to_s[0, 160]}",
                href: "/baybox"}
      end
      if settings["voice_error"] && settings["voice_error_at"] && now - settings["voice_error_at"] < 3 * 86_400
        out << {level: :warn, text: "Learning your review voice is failing: #{settings["voice_error"].to_s[0, 160]}", href: "/baybox#voice"}
      end
    end
    out.sort_by { |p| p[:level] == :error ? 0 : 1 }
  end
end
