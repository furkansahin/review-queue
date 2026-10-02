require "json"
require_relative "diff_view"

# A box's review as a pending review on the pull request: one comment on each
# line it found something on, the summary as the review's body. Pending, so
# nobody sees it but the person whose token made it, until they submit it on
# GitHub -- after reading it, deleting what they disagree with, rewording the
# rest.
#
# The findings come from the box, which read the pull request: text anyone who
# can open one could have steered. So they are only ever drafted, never
# submitted, and each is checked for shape before it is sent.
module GitHubDraft
  MAX_COMMENTS = 100
  MAX_BODY = 20_000
  MAX_SUMMARY = 10_000
  FOOTER = "_Drafted by Leeghwater from a review run in a baybox._"

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
    pending = reviews.find { |r| r["state"] == "PENDING" && r.dig("user", "login").to_s.casecmp?(login.to_s) }
    files = diff_files(gh, repo, pull.dig("base", "sha"), commit)
    placed, loose = findings[:comments].partition { |c| placeable?(files, c) }
    {repo: repo, number: number, url: pull["html_url"].to_s, title: pull["title"].to_s,
     commit: commit, moved: pull.dig("head", "sha") != commit,
     summary: findings[:summary], placed: placed, loose: loose,
     pending: pending && (pending["html_url"] || "#{pull["html_url"]}#pullrequestreview-#{pending["id"]}")}
  end

  def body(plan)
    parts = []
    parts << plan[:summary] unless plan[:summary].to_s.empty?
    unless plan[:loose].empty?
      parts << "Also, on lines this pull request does not change:\n\n" +
               plan[:loose].map { |c| "- `#{c[:path]}` line #{c[:line]}: #{c[:body].gsub(/\s*\n\s*/, " ")}" }.join("\n")
    end
    parts << FOOTER
    parts.join("\n\n")
  end

  # Creates the pending review. {ok:, url:} or {error:}.
  def create(gh, plan)
    return {error: plan[:error]} if plan[:error]
    if plan[:pending]
      return {error: "you already have a pending review on ##{plan[:number]}: submit or discard it on GitHub first"}
    end
    res = gh.post("/repos/#{plan[:repo]}/pulls/#{plan[:number]}/reviews",
                  {commit_id: plan[:commit], body: body(plan),
                   comments: plan[:placed].map { |c| c.slice(:path, :line, :side, :body) }})
    url = res["html_url"].to_s
    {ok: true, url: url.start_with?("https://github.com/") ? url : plan[:url], comments: plan[:placed].size}
  rescue StandardError => e
    said = e.message[/"message"\s*:\s*"([^"]+)"/, 1] || e.message[0, 200]
    hint = e.message.match?(/\AGitHub (403|404)\b/) ? " (the write token needs Pull requests: Read and write)" : ""
    {error: "GitHub refused the draft: #{said}#{hint}"}
  end
end
