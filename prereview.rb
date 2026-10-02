require_relative "db"
require_relative "jobs"
require_relative "crypto"
require_relative "queue_service"

# Reviews made ready before the day starts. On weekday mornings, at the hour
# each person chose in their own time zone, the worker reads their queue and
# starts reviews of the first few pull requests waiting on their review, so
# "review ✓" is already on those rows when they sit down.
#
# The person is not there, so neither is their sign-in: the session's GitHub
# token lives in their cookie. The queue is read with the read-only token
# saved on their Baybox page instead -- the one that already goes into the
# box -- so nothing here can do more than a review started by hand.
module Prereview
  # How late a morning still counts: a worker that was down at seven still
  # prepares at half past, but a deploy in the afternoon does not.
  WINDOW_HOURS = 3
  HOURS = (5..11).freeze
  COUNTS = (1..5).freeze
  DEFAULT_TZ = "Europe/Amsterdam"

  module_function

  # The people whose morning it is and who have not had today's yet, each
  # marked as done for today in the same statement, so two ticks -- or two
  # workers -- never prepare one morning twice. Time zones are Postgres's:
  # Ruby has none without a gem, and the database has them all. at is "now",
  # for tests.
  def claim_due(at = Time.now)
    DB.rows(<<~SQL, [at.utc.iso8601])
      UPDATE user_settings s
      SET prereview_last_on = ($1::timestamptz AT TIME ZONE s.prereview_tz)::date
      WHERE s.prereview_on
        AND extract(isodow FROM $1::timestamptz AT TIME ZONE s.prereview_tz) BETWEEN 1 AND 5
        AND extract(hour FROM $1::timestamptz AT TIME ZONE s.prereview_tz) >= s.prereview_hour
        AND extract(hour FROM $1::timestamptz AT TIME ZONE s.prereview_tz) < s.prereview_hour + #{WINDOW_HOURS}
        AND s.prereview_last_on IS DISTINCT FROM ($1::timestamptz AT TIME ZONE s.prereview_tz)::date
      RETURNING s.login, s.prereview_count, s.watch_label
    SQL
  end

  def allowed?(login)
    ENV.fetch("RQ_ALLOWED_LOGINS", "").split(",").map { |s| s.strip.downcase }.include?(login.to_s.downcase)
  end

  # The pull requests to review: waiting on your review -- not yours, not
  # settled, not a draft, not approved and only waiting to be merged -- in the
  # queue's own order, reddest first, and without a review already in
  # Sessions.
  def pick(rows, reviewed, count)
    rows.select { |r| r[:state] == "To review" && !r[:draft] && !reviewed.key?(r[:key]) }.first(count)
  end

  # Prepares one person's morning. Returns what happened, in words, which the
  # Baybox page shows.
  def run_for(login, count, label: "", now: Time.now)
    return "not prepared: #{login} is no longer allowed to sign in" unless allowed?(login)
    box = DB.row("SELECT * FROM bayboxes WHERE login = $1", [login])
    return "not prepared: no baybox registered" unless box
    token = begin
      box["github_token_enc"].to_s.empty? ? nil : Crypto.decrypt(box["github_token_enc"])
    rescue Crypto::Error
      nil
    end
    return "not prepared: add a GitHub read token on the Baybox page" unless token

    svc = QueueService.new(token: token, scope: ENV.fetch("RQ_SCOPE", "repo:ubicloud/ubicloud"), label: label.to_s)
    snap = svc.snapshot(force: true)
    return "not prepared: could not read your queue: #{snap[:error].to_s[0, 200]}" if snap[:error]
    unless snap[:login].to_s.casecmp?(login)
      return "not prepared: the read token on the Baybox page belongs to #{snap[:login]}, not #{login}"
    end

    picked = pick(snap[:rows], Jobs.by_key(login), count)
    return "nothing to prepare: no pull request was waiting on your review" if picked.empty?
    started, refused = [], []
    picked.each do |r|
      res = Jobs.enqueue(login: login, repo: r[:repo_full], pr_number: r[:number], prepared: true)
      res[:ok] ? started << "##{r[:number]}" : refused << "##{r[:number]} (#{res[:error]})"
    end
    note = started.empty? ? "prepared nothing" : "prepared #{started.join(", ")}"
    note += "; could not start #{refused.join(", ")}" unless refused.empty?
    note
  rescue StandardError => e
    "not prepared: #{e.class}: #{e.message[0, 200]}"
  ensure
    svc&.instance_variable_get(:@gh)&.close_idle
  end

  # One worker tick's worth: everyone due now, one after another.
  def tick(now = Time.now, log: ->(_) {})
    claim_due(now).each do |s|
      note = run_for(s["login"], s["prereview_count"].to_i, label: s["watch_label"], now: now)
      DB.exec("UPDATE user_settings SET prereview_note = $1 WHERE login = $2",
              ["#{now.utc.strftime("%Y-%m-%d %H:%M")} UTC: #{note}", s["login"]])
      log.call("prereview #{s["login"]}: #{note}")
    end
  end

  def settings(login)
    DB.row(<<~SQL, [login]) || {"prereview_on" => false, "prereview_hour" => 7, "prereview_count" => 3, "prereview_tz" => DEFAULT_TZ}
      SELECT prereview_on, prereview_hour, prereview_count, prereview_tz, prereview_last_on, prereview_note
      FROM user_settings WHERE login = $1
    SQL
  end

  # Saves the setting. Returns nil, or what is wrong with it.
  def save(login, on:, hour:, count:, tz:)
    hour = Integer(hour.to_s, 10, exception: false)
    count = Integer(count.to_s, 10, exception: false)
    tz = tz.to_s.strip
    return "pick an hour between #{HOURS.first} and #{HOURS.last}" unless HOURS.include?(hour)
    return "pick between #{COUNTS.first} and #{COUNTS.last} reviews" unless COUNTS.include?(count)
    unless tz.length <= 64 && DB.row("SELECT 1 FROM pg_timezone_names WHERE name = $1", [tz])
      return "#{tz[0, 64]} is not a time zone this server knows"
    end
    DB.exec(<<~SQL, [login, on, hour, count, tz])
      INSERT INTO user_settings (login, prereview_on, prereview_hour, prereview_count, prereview_tz)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (login) DO UPDATE SET prereview_on = EXCLUDED.prereview_on,
        prereview_hour = EXCLUDED.prereview_hour, prereview_count = EXCLUDED.prereview_count,
        prereview_tz = EXCLUDED.prereview_tz, updated_at = now()
    SQL
    nil
  end
end
