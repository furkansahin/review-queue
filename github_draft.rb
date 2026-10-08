require "json"
require "digest"
require "set"
require_relative "diff_view"

# A box's review on the pull request: one comment on each line it found
# something on, the summary as the review's body. Posted by the person, after
# reading every comment on the draft page, unticking what they disagree with
# and rewording the rest -- as Comment, Approve or Request changes, or as a
# pending review to finish on GitHub.
#
# The findings come from the box, which read the pull request: text anyone who
# can open one could have steered. So nothing goes out but what the person
# posts from that page, and each comment is checked for shape before it is
# sent.
module GitHubDraft
  MAX_COMMENTS = 100
  MAX_BODY = 20_000
  MAX_SUMMARY = 10_000
  # GitHub's verdicts, and the words the page uses for them.
  EVENTS = {"COMMENT" => "Comment", "APPROVE" => "Approve", "REQUEST_CHANGES" => "Request changes"}.freeze

  module_function

  # The box's .rq/review.json, as {summary:, comments: [{path:, line:, side:, body:}]},
  # or {error:} saying what is wrong with it.
  def parse(text)
    data = begin
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      return {error: "the box's review.json is not valid JSON"}
    end
    return {error: "the box's review.json is not an object"} unless data.is_a?(Hash)
    raw = data["comments"] || []
    return {error: "the box's review.json has no list of comments"} unless raw.is_a?(Array)
    return {error: "the box wrote more than #{MAX_COMMENTS} comments"} if raw.size > MAX_COMMENTS
    comments = []
    raw.each_with_index do |c, i|
      n = i + 1
      return {error: "comment #{n} is not an object"} unless c.is_a?(Hash)
      path = c["path"].to_s.strip.delete_prefix("./")
      line = c["line"].is_a?(Integer) ? c["line"] : Integer(c["line"].to_s, 10, exception: false)
      side = c["side"].to_s.upcase == "LEFT" ? "LEFT" : "RIGHT"
      body = c["body"].to_s.strip
      if path.empty? || path.start_with?("/") || path.split("/").include?("..") || path.length > 500
        return {error: "comment #{n} names no usable file"}
      end
      return {error: "comment #{n} has no line number"} unless line&.positive?
      return {error: "comment #{n} says nothing"} if body.empty?
      return {error: "comment #{n} is over #{MAX_BODY} characters"} if body.length > MAX_BODY
      comments << {path: path, line: line, side: side, body: body}
    end
    summary = data["summary"].to_s.strip
    return {error: "the summary is over #{MAX_SUMMARY} characters"} if summary.length > MAX_SUMMARY
    {summary: summary, comments: comments}
  end

  # The changed files between the pull request's base and the reviewed commit,
  # as DiffView files: where a comment can be placed.
  def diff_files(gh, repo, base, commit)
    cmp = gh.get("/repos/#{repo}/compare/#{base}...#{commit}")
    (cmp["files"] || []).filter_map do |f|
      next unless f["patch"]
      old = f["previous_filename"] || f["filename"]
      text = "diff --git a/#{old} b/#{f["filename"]}\n" \
             "--- #{f["status"] == "added" ? "/dev/null" : "a/#{old}"}\n" \
             "+++ #{f["status"] == "removed" ? "/dev/null" : "b/#{f["filename"]}"}\n#{f["patch"]}\n"
      DiffView.parse(text, highlight: false).first
    end
  end

  # Whether GitHub can put a comment on that line: it must be in a hunk of the
  # pull request's diff, on the side it names.
  def placeable?(files, c)
    side = c[:side] == "LEFT" ? "old" : "new"
    files.any? do |f|
      next false unless [f.new_path, f.old_path].include?(c[:path])
      !DiffView.find([f], f.path, side, c[:line]).nil?
    end
  end

  # What drafting would do: which comments go on lines and which into the
  # summary, against the commit the box reviewed. {error:} when it cannot.
  def plan(gh, repo, number, commit:, findings:, login:)
    return {error: findings[:error]} if findings[:error]
    return {error: "the box did not say which commit it reviewed"} unless commit.to_s.match?(/\A\h{40}\z/)
    pull = gh.get("/repos/#{repo}/pulls/#{number}")
    return {error: "##{number} is #{pull["merged_at"] ? "merged" : "closed"}"} unless pull["state"] == "open"
    reviews = gh.get("/repos/#{repo}/pulls/#{number}/reviews?per_page=100")
    mine = reviews.find { |r| r["state"] == "PENDING" && r.dig("user", "login").to_s.casecmp?(login.to_s) }
    pending = mine && {id: mine["id"], body: mine["body"].to_s,
                       url: mine["html_url"] || "#{pull["html_url"]}#pullrequestreview-#{mine["id"]}"}
    files = diff_files(gh, repo, pull.dig("base", "sha"), commit)
    placed, loose = findings[:comments].partition { |c| placeable?(files, c) }
    {repo: repo, number: number, url: pull["html_url"].to_s, title: pull["title"].to_s,
     commit: commit, moved: pull.dig("head", "sha") != commit,
     summary: findings[:summary], placed: placed, loose: loose,
     # What the page showed, so a box that rewrote its findings after the page
     # loaded cannot have its new ones drafted under the old ones' ticks.
     digest: Digest::SHA256.hexdigest(JSON.generate([commit, findings[:summary], placed, loose])),
     pending: pending}
  end

  # Only the comments the person kept. indices number them as the page lists
  # them: the ones on lines first, then the ones for the summary.
  #
  # bodies are the person's own wording, by the same numbers, for the
  # comments they changed on the page; summary likewise. An edited comment
  # carries what the box wrote as :original, for the review voice. One
  # emptied is left out, as if unticked.
  def keep(plan, indices, bodies: {}, summary: nil)
    wanted = Array(indices).filter_map { |i| Integer(i.to_s, 10, exception: false) }.to_set
    bodies = (bodies.is_a?(Hash) ? bodies : {}).transform_keys(&:to_s)
    all = plan[:placed] + plan[:loose]
    edited = all.each_with_index.map do |c, i|
      text = bodies[i.to_s]
      next c if text.nil? || same?(text, c[:body])
      text = text.to_s.strip
      return plan.merge(error: "comment #{i + 1} is over #{MAX_BODY} characters") if text.length > MAX_BODY
      c.merge(body: text, original: c[:body])
    end
    keep_at = ->(i) { wanted.include?(i) && !edited[i][:body].to_s.empty? }
    n = plan[:placed].size
    placed = (0...n).select(&keep_at).map { |i| edited[i] }
    loose = (n...all.size).select(&keep_at).map { |i| edited[i] }
    unticked = (0...all.size).reject(&keep_at).map { |i| all[i] }
    out = plan.merge(placed: placed, loose: loose, unticked: unticked, dropped: unticked.size)
    unless summary.nil? || same?(summary, plan[:summary])
      summary = summary.to_s.strip
      return plan.merge(error: "the summary is over #{MAX_SUMMARY} characters") if summary.length > MAX_SUMMARY
      out = out.merge(summary: summary, original_summary: plan[:summary])
    end
    out
  end

  # The same words, whatever the line breaks and spacing.
  def same?(a, b) = a.to_s.split.join(" ") == b.to_s.split.join(" ")

  # The review as the box wrote it, for what was kept: the review voice
  # learns from what the box wrote, not from the person's own first edit.
  def original(kept)
    back = ->(c) { c[:original] ? c.merge(body: c[:original]).except(:original) : c }
    kept.merge(summary: kept[:original_summary] || kept[:summary],
               placed: kept[:placed].map(&back), loose: kept[:loose].map(&back))
  end

  def body(plan)
    parts = []
    parts << plan[:summary] unless plan[:summary].to_s.empty?
    unless plan[:loose].empty?
      parts << "Also, on lines this pull request does not change:\n\n" +
               plan[:loose].map { |c| "- `#{c[:path]}` line #{c[:line]}: #{c[:body].gsub(/\s*\n\s*/, " ")}" }.join("\n")
    end
    parts.join("\n\n")
  end

  # GitHub wants words for these two: a review with neither a body nor a
  # verdict of approval says nothing. nil, or what is missing.
  def needs_body(event, body)
    return nil unless %w[COMMENT REQUEST_CHANGES].include?(event) && body.to_s.strip.empty?
    "GitHub needs a summary to #{EVENTS[event].downcase}: write one above"
  end

  # Posts the review: with event, as that verdict, there for everyone at once;
  # without, as a pending review for the person to finish on GitHub.
  # {ok:, id:, url:, comments:, event:} or {error:}.
  def create(gh, plan, event: nil)
    return {error: plan[:error]} if plan[:error]
    if plan[:pending]
      return {error: "you have a pending review on ##{plan[:number]} already: submit or discard it first"}
    end
    return {error: "#{event.inspect} is not a verdict GitHub knows"} if event && !EVENTS.key?(event)
    if plan[:placed].empty? && plan[:loose].empty? && plan[:summary].to_s.empty? && event != "APPROVE"
      return {error: "every comment is unticked and there is no summary: nothing to post"}
    end
    text = body(plan)
    if (missing = needs_body(event, text)) then return {error: missing} end
    payload = {commit_id: plan[:commit], body: text, comments: plan[:placed].map { |c| c.slice(:path, :line, :side, :body) }}
    payload[:event] = event if event
    res = gh.post("/repos/#{plan[:repo]}/pulls/#{plan[:number]}/reviews", payload)
    url = res["html_url"].to_s
    {ok: true, id: res["id"], url: url.start_with?("https://github.com/") ? url : plan[:url],
     comments: plan[:placed].size, event: event}
  rescue StandardError => e
    {error: "GitHub refused the review: #{explain(e)}"}
  end

  # Submits a pending review that is already on GitHub -- one drafted from
  # here, or begun there -- with this verdict and summary.
  def submit_pending(gh, repo, number, review_id, event:, body:)
    return {error: "#{event.inspect} is not a verdict GitHub knows"} unless EVENTS.key?(event)
    if (missing = needs_body(event, body)) then return {error: missing} end
    res = gh.post("/repos/#{repo}/pulls/#{number}/reviews/#{Integer(review_id)}/events",
                  {event: event, body: body.to_s.strip})
    {ok: true, id: res["id"], url: res["html_url"].to_s, event: event}
  rescue StandardError => e
    {error: "GitHub refused the review: #{explain(e)}"}
  end

  # Throws away a pending review and its comments. Only offered for one drafted
  # from here.
  def discard_pending(gh, repo, number, review_id)
    gh.delete("/repos/#{repo}/pulls/#{number}/reviews/#{Integer(review_id)}")
    {ok: true}
  rescue StandardError => e
    {error: "GitHub would not discard it: #{explain(e)}"}
  end

  def explain(e)
    said = e.message[/"message"\s*:\s*"([^"]+)"/, 1] || e.message[0, 200]
    hint = e.message.match?(/\AGitHub (403|404)\b/) ? " (the write token needs Pull requests: Read and write)" : ""
    "#{said}#{hint}"
  end
end
