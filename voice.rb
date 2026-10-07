require "json"
require "time"
require_relative "db"
require_relative "crypto"
require_relative "queue_service"

# How a person writes review comments, learned from what they post, and
# handed to every review box as .rq/voice.md.
#
# Two sources. A drafted review: what was sent to GitHub as a pending review
# against what the person submitted -- each comment rewritten, posted as it
# was, dropped, or added by them, and what became of the summary. And their
# recent review comments on the repository, drafted or not, so there is a
# voice to follow before the first draft.
#
# Everything here is read with the read token from the Baybox page: the
# worker does it, and nobody is signed in then. Only the person's own words
# are kept -- nobody else's comment on a pull request ever reaches a box this
# way.
module Voice
  # How long a drafted review is watched for its submission.
  WATCH_DAYS = 14
  # A file the box reads at the start of every review: big enough for a
  # couple of dozen examples, small enough not to crowd out the diff.
  MAX_FILE = 24_000
  MAX_EXAMPLE = 900
  MAX_NOTES = 2000
  OWN_COMMENTS = 15

  module_function

  # --- recording a draft ------------------------------------------------------

  # What was sent as a pending review, kept so the submission can be set
  # against it. sent and unticked are [{path:, line:, side:, body:}].
  def record_draft(job_id, review_id:, at:, summary:, sent:, unticked:)
    data = {review_id: review_id, at: at.utc.iso8601, summary: summary.to_s, sent: sent, unticked: unticked}
    DB.exec(<<~SQL, [JSON.generate(data), job_id])
      UPDATE review_jobs SET draft_json = $1, learned_at = NULL, learn_checked_at = NULL, learn_note = NULL
      WHERE id = $2
    SQL
  end

  # --- pairing ----------------------------------------------------------------

  def words(text) = text.to_s.split.size

  # Drafted comments against posted ones: the same line first, then the
  # nearest within a few lines in the same file, since a comment moved by a
  # line is still the same comment. [[drafted, posted]...], unmatched drafted,
  # unmatched posted.
  def pair(drafted, posted)
    left = posted.dup
    pairs = []
    rest = []
    drafted.each do |d|
      i = left.index { |p| p[:path] == d[:path] && p[:line] == d[:line] && p[:side] == d[:side] }
      if i
        pairs << [d, left.delete_at(i)]
      else
        rest << d
      end
    end
    unmatched = []
    rest.each do |d|
      near = left.each_with_index.select { |p, _| p[:path] == d[:path] && (p[:line].to_i - d[:line].to_i).abs <= 5 }
      if (best = near.min_by { |p, _| (p[:line].to_i - d[:line].to_i).abs })
        pairs << [d, left.delete_at(best[1])]
      else
        unmatched << d
      end
    end
    [pairs, unmatched, left]
  end

  def same?(a, b) = a.to_s.split.join(" ") == b.to_s.split.join(" ")

  # --- learning from a submitted draft ---------------------------------------

  # Reads what became of a drafted review. nil while it is still pending (or
  # gone with nothing written in its place yet); otherwise the examples are
  # stored and a note saying what was learned is returned.
  def harvest(gh, job)
    d = JSON.parse(job["draft_json"], symbolize_names: true)
    login, repo, number = job["login"], job["repo"], job["pr_number"].to_i
    base = "/repos/#{repo}/pulls/#{number}"
    review = begin
      gh.get("#{base}/reviews/#{d[:review_id]}")
    rescue StandardError => e
      raise unless e.message.start_with?("GitHub 404")
      nil
    end
    return nil if review && review["state"] == "PENDING"
    if review.nil?
      # Discarded. If they wrote a review of their own instead, learn from that.
      since = Time.parse(d[:at])
      review = gh.get("#{base}/reviews?per_page=100").select do |r|
        r.dig("user", "login").to_s.casecmp?(login) && r["state"] != "PENDING" &&
          r["submitted_at"] && Time.parse(r["submitted_at"]) >= since
      end.min_by { |r| r["submitted_at"] }
      return nil unless review
    end

    comments = []
    (1..5).each do |page|
      batch = gh.get("#{base}/comments?per_page=100&page=#{page}")
      comments.concat(batch.select { |c| c["pull_request_review_id"] == review["id"] })
      break if batch.size < 100
    end
    posted = comments.map do |c|
      {path: c["path"].to_s, line: (c["original_line"] || c["line"]).to_i, side: c["side"] || "RIGHT", body: c["body"].to_s}
    end
    # What the box wrote; an edit on the draft page is already the person's.
    drafted = Array(d[:sent]).map { |c| c.slice(:path, :line, :side).merge(body: c[:original] || c[:body]) }
    pairs, dropped, added = pair(drafted, posted)
    dropped += Array(d[:unticked]).map { |c| c.slice(:path, :line, :side, :body) }

    rows = []
    pairs.each { |dr, po| rows << [same?(dr[:body], po[:body]) ? "kept" : "rewritten", dr, po] }
    dropped.each { |dr| rows << ["dropped", dr, nil] }
    added.each { |po| rows << ["added", nil, po] }
    summary_posted = review["body"].to_s.strip
    unless d[:summary].to_s.strip.empty? && summary_posted.empty?
      rows << ["summary", {path: "", line: 0, body: d[:summary]}, {path: "", line: 0, body: summary_posted}]
    end

    DB.with do |conn|
      conn.transaction do
        conn.exec_params("DELETE FROM voice_examples WHERE job_id = $1", [job["id"]])
        rows.each do |kind, dr, po|
          c = dr || po
          conn.exec_params(<<~SQL, [login, job["id"], repo, number, c[:path], c[:line], kind, dr && dr[:body], po && po[:body]])
            INSERT INTO voice_examples (login, job_id, repo, pr_number, path, line, kind, drafted, posted)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end
      end
    end
    counts = rows.map(&:first).tally
    parts = []
    parts << "#{counts["rewritten"]} rewritten" if counts["rewritten"]
    parts << "#{counts["kept"]} posted as drafted" if counts["kept"]
    parts << "#{counts["dropped"]} dropped" if counts["dropped"]
    parts << "#{counts["added"]} added by you" if counts["added"]
    parts << (summary_posted.empty? ? "summary dropped" : "summary rewritten") if counts["summary"]
    "learned from your submitted review: #{parts.empty? ? "nothing to compare" : parts.join(", ")}"
  end

  # --- your recent comments ---------------------------------------------------

  def scope_repos
    ENV.fetch("RQ_SCOPE", "repo:ubicloud/ubicloud").scan(%r{repo:([\w.\-]+/[\w.\-]+)}i).flatten
  end

  # The person's most recent review comments in the watched repositories,
  # replacing the ones kept before.
  def refresh_own(gh, login)
    mine = []
    scope_repos.each do |repo|
      (1..3).each do |page|
        batch = gh.get("/repos/#{repo}/pulls/comments?sort=created&direction=desc&per_page=100&page=#{page}")
        batch.each do |c|
          next unless c.dig("user", "login").to_s.casecmp?(login)
          num = c["pull_request_url"].to_s[%r{/pulls/(\d+)\z}, 1].to_i
          mine << [repo, num, c["path"].to_s, (c["original_line"] || c["line"]).to_i, c["body"].to_s, c["created_at"]]
        end
        break if batch.size < 100 || mine.size >= OWN_COMMENTS
      end
    end
    mine = mine.sort_by { |m| m[5].to_s }.reverse.first(OWN_COMMENTS)
    DB.with do |conn|
      conn.transaction do
        conn.exec_params("DELETE FROM voice_examples WHERE login = $1 AND kind = 'own'", [login])
        mine.each do |repo, num, path, line, body, _|
          conn.exec_params(<<~SQL, [login, repo, num, path, line, body])
            INSERT INTO voice_examples (login, repo, pr_number, path, line, kind, posted)
            VALUES ($1, $2, $3, $4, $5, 'own', $6)
          SQL
        end
        conn.exec_params(<<~SQL, [login])
          INSERT INTO user_settings (login, voice_own_at) VALUES ($1, now())
          ON CONFLICT (login) DO UPDATE SET voice_own_at = now()
        SQL
      end
    end
    mine.size
  end

  # --- the file the box reads -------------------------------------------------

  def notes(login)
    DB.row("SELECT voice_notes FROM user_settings WHERE login = $1", [login])&.fetch("voice_notes").to_s
  end

  def save_notes(login, text)
    text = text.to_s.strip
    return "your notes are over #{MAX_NOTES} characters" if text.length > MAX_NOTES
    DB.exec(<<~SQL, [login, text])
      INSERT INTO user_settings (login, voice_notes) VALUES ($1, $2)
      ON CONFLICT (login) DO UPDATE SET voice_notes = EXCLUDED.voice_notes, updated_at = now()
    SQL
    nil
  end

  def forget(login) = DB.exec("DELETE FROM voice_examples WHERE login = $1", [login])

  def counts(login)
    DB.rows("SELECT kind, count(*) AS n FROM voice_examples WHERE login = $1 GROUP BY kind", [login])
      .to_h { |r| [r["kind"], r["n"].to_i] }
  end

  def clip(text) = (t = text.to_s.strip).length > MAX_EXAMPLE ? "#{t[0, MAX_EXAMPLE]}…" : t
  def quote(text) = clip(text).lines.map { |l| "> #{l.rstrip}" }.join("\n")
  def where(r) = r["path"].to_s.empty? ? "##{r["pr_number"]}" : "`#{r["path"]}` line #{r["line"]} (##{r["pr_number"]})"

  # The voice file, or nil when there is nothing to say yet.
  def compose(login)
    mine = notes(login)
    ex = DB.rows("SELECT * FROM voice_examples WHERE login = $1 ORDER BY at DESC, id DESC LIMIT 300", [login])
    return nil if mine.empty? && ex.empty?
    by = ex.group_by { |r| r["kind"] }
    out = +"# How #{login} writes review comments\n\n"
    out << "They post your comments on GitHub as their own. Write every comment in review.json, and its " \
           "summary, the way they would have written it -- their length, their tone, how they ask and " \
           "suggest, what they leave out -- and only the findings they would bother to post.\n"
    unless mine.empty?
      out << "\n## In their own words\n\n#{mine}\n"
    end

    judged = %w[rewritten kept dropped].sum { |k| by.fetch(k, []).size }
    if judged.positive?
      posted = by.fetch("rewritten", []).size + by.fetch("kept", []).size
      drafted_words = %w[rewritten kept dropped].flat_map { |k| by.fetch(k, []) }.map { |r| words(r["drafted"]) }
      posted_words = %w[rewritten kept added own].flat_map { |k| by.fetch(k, []) }.map { |r| words(r["posted"]) }
      out << "\n## In numbers\n\n"
      out << "- Of #{judged} comments drafted for them, they posted #{posted}" \
             "#{by["kept"] ? ", #{by["kept"].size} of them unchanged" : ""}.\n"
      unless posted_words.empty?
        out << "- Their comments run about #{posted_words.sum / posted_words.size} words; " \
               "the drafts ran about #{drafted_words.sum / [drafted_words.size, 1].max}.\n"
      end
      if (s = by["summary"])
        out << "- Summaries: #{s.count { |r| r["posted"].to_s.strip.empty? }} of #{s.size} drafted summaries were deleted before posting.\n"
      end
    end

    section = lambda do |title, intro, rows, limit, &each|
      next if rows.nil? || rows.empty?
      out << "\n## #{title}\n\n#{intro}\n"
      rows.first(limit).each { |r| out << "\n" << each.call(r) << "\n" }
    end
    section.call("Rewritten", "What a review drafted, and what they posted instead.", by["rewritten"], 10) do |r|
      "### #{where(r)}\nDrafted:\n#{quote(r["drafted"])}\n\nThey wrote:\n#{quote(r["posted"])}"
    end
    section.call("Written by them", "Comments they added that no review had drafted: what they look for.", by["added"], 6) do |r|
      "### #{where(r)}\n#{quote(r["posted"])}"
    end
    section.call("Dropped", "Drafted, and not posted: the kind of finding they do not want raised.", by["dropped"], 6) do |r|
      "### #{where(r)}\n#{quote(r["drafted"])}"
    end
    section.call("Their recent comments", "From their own reviews, drafted or not.", by["own"], OWN_COMMENTS) do |r|
      "### #{where(r)}\n#{quote(r["posted"])}"
    end
    section.call("Posted as drafted", "These needed no change.", by["kept"], 3) do |r|
      "### #{where(r)}\n#{quote(r["posted"])}"
    end
    out.length > MAX_FILE ? "#{out[0, MAX_FILE]}\n\n(cut short)\n" : out
  end

  # --- the worker's part ------------------------------------------------------

  def read_client(login)
    box = DB.row("SELECT github_token_enc FROM bayboxes WHERE login = $1", [login])
    enc = box && box["github_token_enc"].to_s
    return nil if enc.nil? || enc.empty?
    GitHubClient.new(Crypto.decrypt(enc))
  rescue Crypto::Error
    nil
  end

  # Drafts waiting to be submitted, each looked at every few minutes for two
  # weeks; and once a day, each person's recent comments.
  def tick(log: ->(_) {})
    DB.rows(<<~SQL).each do |job|
      UPDATE review_jobs SET learn_checked_at = now()
      WHERE id IN (
        SELECT id FROM review_jobs
        WHERE draft_json IS NOT NULL AND learned_at IS NULL
          AND (draft_json::jsonb ->> 'at')::timestamptz > now() - interval '#{WATCH_DAYS} days'
          AND (learn_checked_at IS NULL OR learn_checked_at < now() - interval '5 minutes')
        LIMIT 20)
      RETURNING *
    SQL
      gh = read_client(job["login"])
      next unless gh
      note = harvest(gh, job)
      next unless note
      DB.exec("UPDATE review_jobs SET learned_at = now(), learn_note = $1 WHERE id = $2", [note, job["id"]])
      failed(job["login"], nil)
      log.call("voice #{job["login"]} ##{job["pr_number"]}: #{note}")
    rescue StandardError => e
      failed(job["login"], "could not read your review of ##{job["pr_number"]}: #{e.message[0, 200]}")
      log.call("voice: could not read ##{job["pr_number"]}: #{e.class}: #{e.message[0, 200]}")
    end

    DB.rows(<<~SQL).each do |row|
      SELECT b.login FROM bayboxes b LEFT JOIN user_settings s ON s.login = b.login
      WHERE b.github_token_enc IS NOT NULL
        AND (s.voice_own_at IS NULL OR s.voice_own_at < now() - interval '20 hours')
    SQL
      gh = read_client(row["login"])
      next unless gh
      n = refresh_own(gh, row["login"])
      failed(row["login"], nil)
      log.call("voice #{row["login"]}: #{n} recent comments")
    rescue StandardError => e
      # Tried again tomorrow rather than every minute.
      DB.exec(<<~SQL, [row["login"]])
        INSERT INTO user_settings (login, voice_own_at) VALUES ($1, now())
        ON CONFLICT (login) DO UPDATE SET voice_own_at = now()
      SQL
      failed(row["login"], "could not read your recent review comments: #{e.message[0, 200]}")
      log.call("voice: could not read #{row["login"]}'s comments: #{e.class}: #{e.message[0, 200]}")
    end
  end

  # Kept where the health line on the queue page reads it; nil clears it.
  def failed(login, message)
    DB.exec(<<~SQL, [login, message])
      INSERT INTO user_settings (login, voice_error, voice_error_at) VALUES ($1, $2, CASE WHEN $2::text IS NULL THEN NULL ELSE now() END)
      ON CONFLICT (login) DO UPDATE SET voice_error = EXCLUDED.voice_error, voice_error_at = EXCLUDED.voice_error_at
    SQL
  end
end
