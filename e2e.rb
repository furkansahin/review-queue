require "erb"

# Runs the repository's E2E on a pull request from a fork. The E2E workflow is
# only ever dispatched on a branch of the repository itself, and a fork's
# branch is not one, so /run-e2e cannot reach it. Here the fork's head commit
# is given a branch of the repository -- <prefix>/<their login>-<their branch>
# -- pointing at exactly that commit, and E2E is dispatched on it. The same
# commit, not a copy: Require E2E looks for a passing run on the pull
# request's own head, so the run counts for the pull request.
#
# Their code runs with the E2E secrets. So this is only done on the commit the
# person was shown, and never on one that changes .github/, which decides what
# runs and with which secrets.
module E2E
  WORKFLOW = ENV.fetch("RQ_E2E_WORKFLOW", "e2e.yml")
  PROVIDERS = %w[metal aws gcp].freeze
  # Pages of changed files read before giving up: past 3000 files nothing can
  # say the pull request leaves .github/ alone, so it is refused.
  MAX_FILE_PAGES = 30

  module_function

  # Everyone's own branch prefix: the first word of their GitHub name, as
  # "furkan" for Furkan Sahin, or their login when they have set no name.
  def prefix(user)
    name = user["name"].to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, "")
    first = name.split.first.to_s.downcase.gsub(/[^a-z0-9-]/, "")
    first.empty? ? user["login"].to_s.downcase.gsub(/[^a-z0-9-]/, "") : first
  end

  # A prefix someone sets for themselves, as one part of a branch name: lower
  # case, letters, digits and . _ -, starting with a letter or digit, and
  # nothing git refuses in a ref. nil when it is not one.
  def clean_prefix(value)
    v = value.to_s.strip.downcase
    return nil unless v.match?(/\A[a-z0-9][a-z0-9._-]{0,38}\z/)
    return nil if v.include?("..") || v.end_with?(".", ".lock")
    v
  end

  def branch_for(prefix, owner, ref) = "#{prefix}/#{owner.to_s.downcase}-#{ref}"

  # A branch in an API path: each part escaped, the slashes between kept.
  def ref_path(branch) = branch.split("/").map { |part| ERB::Util.url_encode(part) }.join("/")

  def runs_url(repo, branch) =
    "https://github.com/#{repo}/actions/workflows/#{WORKFLOW}?query=#{ERB::Util.url_encode("branch:#{branch}")}"

  # What the button would do, read from GitHub now: the pull request's head,
  # the branch it would get, whether that branch is there already, and
  # whether the change reaches into .github/. {error:} when it cannot be done.
  def plan(gh, repo, number, prefix)
    pull = gh.get("/repos/#{repo}/pulls/#{number}")
    unless pull["state"] == "open"
      return {error: "##{number} is #{pull["merged_at"] ? "merged" : "closed"}"}
    end
    if pull.dig("head", "repo", "full_name").to_s.casecmp?(repo)
      return {error: "##{number} is from a branch of #{repo} itself: comment /run-e2e on it instead"}
    end
    owner = pull.dig("head", "user", "login").to_s
    ref = pull.dig("head", "ref").to_s
    sha = pull.dig("head", "sha").to_s
    unless sha.match?(/\A\h{40}\z/) && !owner.empty? && !ref.empty?
      return {error: "GitHub did not say which commit ##{number} is at"}
    end
    files = changed_files(gh, repo, number)
    branch = branch_for(prefix, owner, ref)
    existing = gh.try("/repos/#{repo}/git/ref/heads/#{ref_path(branch)}")
    {repo: repo, number: number, title: pull["title"].to_s, url: pull["html_url"].to_s,
     owner: owner, ref: ref, sha: sha, branch: branch,
     existing: existing.is_a?(Hash) ? existing.dig("object", "sha") : nil,
     files: files&.size, touches_ci: files.nil? || files.any? { |f| f.start_with?(".github/") }}
  end

  # Every path the pull request touches, a rename's old one too; nil when
  # there are too many to read.
  def changed_files(gh, repo, number)
    files = []
    (1..MAX_FILE_PAGES).each do |page|
      batch = gh.get("/repos/#{repo}/pulls/#{number}/files?per_page=100&page=#{page}")
      batch.each do |f|
        files << f["filename"].to_s
        files << f["previous_filename"].to_s if f["previous_filename"]
      end
      return files if batch.size < 100
    end
    nil
  end

  # Gives the branch the commit the person was shown, and starts E2E on it.
  # Returns {ok:, branch:, run_url:} or {error:}.
  def run(gh, plan, sha:, providers:)
    return {error: plan[:error]} if plan[:error]
    unless plan[:sha] == sha.to_s
      return {error: "##{plan[:number]} has moved on since you looked: it is at #{plan[:sha][0, 7]} now, " \
                     "not #{sha.to_s[0, 7]}. Read it again first."}
    end
    if plan[:touches_ci]
      return {error: "##{plan[:number]} changes .github/, which decides what E2E runs and with which secrets, " \
                     "so it is not pushed from here"}
    end
    providers = Array(providers).map(&:to_s) & PROVIDERS
    return {error: "pick at least one provider"} if providers.empty?

    repo, branch = plan[:repo], plan[:branch]
    begin
      if plan[:existing].nil?
        gh.post("/repos/#{repo}/git/refs", {ref: "refs/heads/#{branch}", sha: sha})
      elsif plan[:existing] != sha
        # The mirror of their branch, so it follows their head -- a rebase
        # of theirs included.
        gh.patch("/repos/#{repo}/git/refs/heads/#{ref_path(branch)}", {sha: sha, force: true})
      end
    rescue StandardError => e
      return {error: "could not push #{branch}: #{explain(e)}"}
    end

    begin
      res = gh.post("/repos/#{repo}/actions/workflows/#{WORKFLOW}/dispatches",
                    {ref: branch, inputs: {providers: providers.join(",")}, return_run_details: true})
    rescue StandardError => e
      return {error: "pushed #{branch}, but could not start E2E: #{explain(e)}"}
    end
    {ok: true, branch: branch, run_url: res["html_url"].to_s.start_with?("https://github.com/") ? res["html_url"] : runs_url(repo, branch)}
  end

  # GitHub's own words, and what to do about the usual one: a write token
  # without the permission this needs.
  def explain(e)
    said = e.message[/"message"\s*:\s*"([^"]+)"/, 1] || e.message[0, 200]
    hint = e.message.match?(/\AGitHub (403|404)\b/) ? " (the write token needs Contents and Actions: Read and write)" : ""
    "#{said}#{hint}"
  end
end
