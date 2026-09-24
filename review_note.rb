require_relative "diff_view"

# A review from the changes page, written out as the follow-up the box reads:
# each comment with where it is and the code it is about, then the overall
# note, then what to do with them.
module ReviewNote
  module_function

  MAX_COMMENTS = 100
  MAX_COMMENT = 4000
  MAX_OVERALL = 8000
  # Under what Runner puts in the box for one follow-up.
  MAX_TEXT = 60_000
  QUOTE = 300

  # comments: [{"view" => "branch" or a commit sha, "path", "side" => "new" | "old",
  #             "line" => number, "text" => the line as the page showed it, "body"}]
  # Returns {text:, count:} or {error:}.
  def compose(diff, comments, overall, head: "")
    return {error: "there is no diff for this session yet"} unless diff.is_a?(Hash)
    return {error: "that review did not arrive whole; reload the page and send it again"} unless comments.is_a?(Array)
    comments = comments.select { |c| c.is_a?(Hash) && !c["body"].to_s.strip.empty? }
    overall = overall.to_s.strip
    return {error: "write a comment on a line, or an overall note, first"} if comments.empty? && overall.empty?
    return {error: "that is more than #{MAX_COMMENTS} comments; send them in two goes"} if comments.size > MAX_COMMENTS
    if comments.any? { |c| c["body"].to_s.length > MAX_COMMENT }
      return {error: "one comment is over #{MAX_COMMENT} characters"}
    end
    return {error: "the overall note is over #{MAX_OVERALL} characters"} if overall.length > MAX_OVERALL

    parsed = {}
    items = comments.each_with_index.map do |c, i|
      view = c["view"].to_s
      commit = Array(diff[:commits]).find { |k| k[:sha] == view }
      patch = commit ? commit[:patch] : diff[:branch]
      files = (parsed[view] ||= DiffView.parse(patch.to_s, highlight: false))
      path = c["path"].to_s[0, 500]
      side = c["side"] == "old" ? "old" : "new"
      number = Integer(c["line"].to_s, 10, exception: false)
      line = number && DiffView.find(files, path, side, number)
      shown = c["text"].to_s
      # The page's copy of the line is what the person was looking at. If the
      # diff no longer has that line there -- a follow-up has moved things --
      # say so, rather than quote whatever sits at that number now.
      moved = line.nil? || line.text != shown
      where = +"`#{path}`"
      where << (side == "old" ? ", removed line #{number}" : " line #{number}") if number
      where << %( (in commit #{view[0, 10]} "#{commit[:subject]}")) if commit
      quote = (moved ? shown : line.text).strip[0, QUOTE]
      body = c["body"].to_s.strip.gsub("\n", "\n   ")
      entry = +"#{i + 1}. #{where}\n   > #{quote}"
      entry << "\n   (the branch has changed since; this line is no longer there as quoted)" if moved
      entry << "\n   #{body}"
      entry
    end

    text = +"Here is my review of your branch"
    text << ", as it stood at #{head[0, 10]}" unless head.empty?
    text << ". Address every comment: change the code, or say why you would not. Then " \
            "check the branch against your skills again, commit the way they say, and " \
            "update .rq/pr.md if the description no longer fits. Finish by going through " \
            "the comments one by one: what you did for each."
    text << "\n\n" << items.join("\n\n") unless items.empty?
    text << "\n\nOverall:\n" << overall unless overall.empty?
    return {error: "that review is too long to send in one go; send it in two"} if text.bytesize > MAX_TEXT
    {text: text, count: comments.size}
  end
end
