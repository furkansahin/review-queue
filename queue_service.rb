require "net/http"
require "json"
require "uri"
require "time"

class GitHubClient
  API = "https://api.github.com"

  attr_reader :rate_remaining

  def initialize(token)
    @token = token
    @mutex = Mutex.new
  end

  def get(path)
    uri = URI(path.start_with?("http") ? path : API + path)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["User-Agent"] = "review-queue"
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 25) do |http|
      http.request(req)
    end
    @mutex.synchronize { @rate_remaining = res["x-ratelimit-remaining"] }
    unless res.is_a?(Net::HTTPSuccess)
      raise "GitHub #{res.code} on #{uri.path}: #{res.body.to_s[0, 200]}"
    end
    JSON.parse(res.body)
  end

  # Best-effort: nil instead of raising (used for optional data like check runs).
  def try(path)
    get(path)
  rescue StandardError
    nil
  end
end

# Fetches the queue from GitHub and caches the computed snapshot.
class QueueService
  BUCKET_LABELS = {review: "Review requested", mention: "Mentions me", label: nil, mine: "My PRs"}.freeze

  # quick_lines: churn at or below which a PR counts as a "quick win".
  # lines_per_min: rough review-reading rate behind the "~3m" estimate.
  def initialize(token:, scope:, label:, warn_days: 2, hot_days: 4, stale_days: 7, ttl: 300, concurrency: 5, per_page: 50,
    quick_lines: 50, lines_per_min: 20)
    @gh = GitHubClient.new(token)
    @scope = scope
    @label = label
    @warn_days = warn_days
    @hot_days = hot_days
    @stale_days = stale_days
    @ttl = ttl
    @concurrency = concurrency
    @per_page = per_page
    @quick_lines = quick_lines
    @lines_per_min = lines_per_min
    @lock = Mutex.new
    @snapshot = nil
  end

  attr_reader :scope, :label, :quick_lines

  def buckets
    [
      {key: :review, label: "Review requested", q: "#{@scope} is:open is:pr review-requested:@me"},
      {key: :mention, label: "Mentions me", q: "#{@scope} is:open is:pr mentions:@me"},
      {key: :label, label: @label, q: %(#{@scope} is:open is:pr label:"#{@label}")},
      {key: :mine, label: "My PRs", q: "#{@scope} is:open is:pr author:@me"}
    ]
  end

  def tabs
    [{key: :all, label: "All"}] +
      buckets.map { |b| {key: b[:key], label: b[:label]} } +
      [{key: :quick, label: "Quick wins"}, {key: :snoozed, label: "Snoozed"}]
  end

  def snapshot(force: false)
    @lock.synchronize do
      fresh = @snapshot && (Time.now - @snapshot[:fetched_at] < @ttl)
      return @snapshot if fresh && !force

      begin
        @snapshot = build
      rescue StandardError => e
        @snapshot = (@snapshot || {rows: [], login: nil, fetched_at: Time.now}).merge(
          error: e.message, fetched_at: Time.now, rate: @gh.rate_remaining
        )
      end
      @snapshot
    end
  end

  def counts(rows)
    out = {all: {open: rows.count { |r| !r[:settled] }, total: rows.size}}
    (buckets.map { |b| b[:key] } + [:quick]).each do |key|
      in_b = rows.select { |r| r[:buckets].include?(key) }
      out[key] = {open: in_b.count { |r| !r[:settled] }, total: in_b.size}
    end
    out
  end

  private

  def build
    login = @gh.get("/user").fetch("login")

    entries = {}
    threaded(buckets) do |b|
      res = @gh.get("/search/issues?per_page=#{@per_page}&sort=updated&q=#{URI.encode_www_form_component(b[:q])}")
      [b[:key], res["items"] || []]
    end.each do |key, items|
      next unless items
      items.each do |item|
        e = entries[item["html_url"]] ||= {item: item, buckets: []}
        e[:buckets] << key
      end
    end

    prs = threaded(entries.values) { |entry| detail(entry, login) }.compact
    rows = prs.map { |pr| row(pr, login) }.sort_by { |r| r[:sort_key] }

    {rows: rows, login: login, fetched_at: Time.now, rate: @gh.rate_remaining, error: nil,
     counts: counts(rows), reviews_7d: reviews_this_week(prs)}
  end

  # Reviews I posted in the last 7 days. Derived from timelines already
  # fetched, so it costs no extra API calls -- but it only sees PRs still
  # matching RQ_SCOPE, so it undercounts once a PR drops out of the queue.
  REVIEW_KINDS = ["approved", "changes requested", "review", "review comment"].freeze

  def reviews_this_week(prs)
    cutoff = Time.now - (7 * 86_400)
    prs.count do |pr|
      m = pr[:my_last]
      m && !pr[:mine] && m[:at] >= cutoff && REVIEW_KINDS.include?(m[:kind])
    end
  end

  def threaded(items)
    queue = items.each_with_index.to_a
    results = Array.new(items.size)
    qlock = Mutex.new
    workers = [@concurrency, items.size].min
    return [] if workers.zero?
    workers.times.map do
      Thread.new do
        loop do
          job = qlock.synchronize { queue.shift }
          break unless job
          item, i = job
          begin
            results[i] = yield(item)
          rescue StandardError
            results[i] = nil
          end
        end
      end
    end.each(&:join)
    results
  end

  def detail(entry, login)
    item = entry[:item]
    owner, repo = item["repository_url"].match(%r{repos/([^/]+)/([^/]+)\z}).captures
    n = item["number"]
    base = "/repos/#{owner}/#{repo}"

    pull, reviews, comments, rev_comments = threaded(
      ["#{base}/pulls/#{n}",
       "#{base}/pulls/#{n}/reviews?per_page=100",
       "#{base}/issues/#{n}/comments?per_page=100",
       "#{base}/pulls/#{n}/comments?per_page=100"]
    ) { |p| @gh.get(p) }
    return nil unless pull

    sha = pull.dig("head", "sha")
    commit_at = Time.parse(pull["created_at"])
    ci = :none
    if sha
      checks, commit = threaded(["#{base}/commits/#{sha}/check-runs?per_page=100", "#{base}/commits/#{sha}"]) { |p| @gh.try(p) }
      if commit
        c = commit["commit"]
        commit_at = Time.parse((c["committer"] || c["author"])["date"])
      end
      runs = checks && checks["check_runs"]
      if runs && !runs.empty?
        ci = if runs.any? { |r| %w[failure timed_out cancelled action_required].include?(r["conclusion"]) }
          :fail
        elsif runs.any? { |r| r["status"] != "completed" }
          :pending
        elsif runs.all? { |r| %w[success neutral skipped].include?(r["conclusion"]) }
          :pass
        else
          :pending
        end
      end
    end

    events = []
    (comments || []).each { |c| events << {at: Time.parse(c["created_at"]), who: c.dig("user", "login"), kind: "comment"} }
    (rev_comments || []).each { |c| events << {at: Time.parse(c["created_at"]), who: c.dig("user", "login"), kind: "review comment"} }
    (reviews || []).reject { |r| r["state"] == "PENDING" || r["submitted_at"].nil? }.each do |r|
      kind = case r["state"]
      when "APPROVED" then "approved"
      when "CHANGES_REQUESTED" then "changes requested"
      else "review"
      end
      events << {at: Time.parse(r["submitted_at"]), who: r.dig("user", "login"), kind: kind}
    end
    events << {at: commit_at, who: pull.dig("user", "login"), kind: "push"}
    events.sort_by! { |e| e[:at] }

    last = events.last
    my_last = events.select { |e| e[:who] == login }.last
    last_other = events.reverse.find { |e| e[:who] != login }

    {
      url: item["html_url"], title: item["title"], number: n, repo: repo, owner: owner,
      author: pull.dig("user", "login") || "?", draft: !!pull["draft"], ci: ci,
      labels: (item["labels"] || []).map { |l| l["name"] },
      buckets: entry[:buckets],
      mine: pull.dig("user", "login") == login,
      last: last, my_last: my_last, last_other: last_other,
      i_acted: !!(my_last && last && my_last[:at] >= last[:at]),
      changed: pull["changed_files"], churn: (pull["additions"].to_i + pull["deletions"].to_i)
    }
  end

  def row(pr, login)
    settled = pr[:i_acted]
    wait_from = settled ? pr.dig(:my_last, :at) : (pr.dig(:last_other, :at) || pr.dig(:last, :at))
    days = wait_from ? (Time.now - wait_from) / 86_400.0 : 0
    bar, text = age_colors(days, settled)

    state, state_bg, state_color =
      if settled && pr[:mine]
        ["Waiting on them", "var(--state-them-bg)", "var(--state-them-fg)"]
      elsif settled
        ["Reviewed", "var(--state-done-bg)", "var(--state-done-fg)"]
      elsif pr[:mine]
        ["Your turn", "var(--state-yours-bg)", "var(--state-yours-fg)"]
      else
        ["To review", "var(--state-todo-bg)", "var(--state-todo-fg)"]
      end

    churn = pr[:churn].to_i
    # A quick win is small and not a draft. Deliberately independent of whether
    # it is settled -- the "Hide settled" toggle already covers that axis.
    quick = churn.positive? && churn <= @quick_lines && !pr[:draft]

    chips = []
    chips << chip(pr[:draft] ? "draft" : nil, :grey)
    pr[:labels].select { |l| l.downcase == @label.downcase }.each { |l| chips << chip(l, :blue) }
    chips << chip("@#{login}", :violet) if pr[:buckets].include?(:mention)
    chips.compact!

    {
      key: "#{pr[:repo]}##{pr[:number]}",
      last_at: pr.dig(:last, :at),
      buckets: pr[:buckets] + (quick ? [:quick] : []), settled: settled,
      # Reddest first: oldest wait_from means most days waiting, which is what
      # age_colors ramps red. Settled rows ("Reviewed" / "Waiting on them") are
      # grey regardless of age, so they sink below everything. A row with no
      # timeline events reads as fresh, so it sorts last within its group.
      sort_key: [settled ? 1 : 0, wait_from ? wait_from.to_i : Float::INFINITY],
      url: pr[:url], title: pr[:title], ref: "#{pr[:repo]} ##{pr[:number]}", author: pr[:author],
      state: state, state_bg: state_bg, state_color: state_color, chips: chips,
      row_bg: settled ? "var(--row-settled)" : "var(--row)",
      age_color: bar, age_text_color: text, age: ago(wait_from),
      last_activity: "#{ago(pr.dig(:last, :at))} ago",
      last_actor: pr[:last] ? "#{pr[:last][:who] == login ? "you" : pr[:last][:who]} · #{pr[:last][:kind]}" : "—",
      my_action: pr[:my_last] ? "#{ago(pr[:my_last][:at])} ago" : "never",
      my_action_kind: pr[:my_last] ? pr[:my_last][:kind] : "no activity from you",
      quick: quick, churn: churn, changed: pr[:changed].to_i,
      read_est: churn.positive? ? "~#{[(churn / @lines_per_min.to_f).ceil, 1].max}m" : "—",
      size_sub: churn.positive? ? "±#{churn} · #{pr[:changed].to_i}f" : "no diff data",
      ci: pr[:ci] == :none ? "—" : pr[:ci].to_s,
      ci_color: {fail: "var(--ci-fail)", pass: "var(--ci-pass)",
                 pending: "var(--ci-pending)", none: "var(--ci-none)"}[pr[:ci]]
    }
  end

  def chip(text, tone)
    return nil unless text
    palette = {
      grey: ["var(--chip-grey-bg)", "var(--chip-grey-br)", "var(--chip-grey-fg)"],
      blue: ["var(--chip-blue-bg)", "var(--chip-blue-br)", "var(--chip-blue-fg)"],
      violet: ["var(--chip-violet-bg)", "var(--chip-violet-br)", "var(--chip-violet-fg)"],
      faint: ["var(--chip-faint-bg)", "var(--chip-faint-br)", "var(--chip-faint-fg)"]
    }[tone]
    {text: text, bg: palette[0], border: palette[1], color: palette[2]}
  end

  def age_colors(days, settled)
    return ["var(--age-idle-bar)", "var(--age-idle-fg)"] if settled
    return ["var(--age-stale-bar)", "var(--age-stale-fg)"] if days >= @stale_days
    return ["var(--age-hot-bar)", "var(--age-hot-fg)"] if days >= @hot_days
    return ["var(--age-warn-bar)", "var(--age-warn-fg)"] if days >= @warn_days
    ["var(--age-fresh-bar)", "var(--age-fresh-fg)"]
  end

  def ago(time)
    return "—" unless time
    mins = ((Time.now - time) / 60).floor
    return "#{[mins, 1].max}m" if mins < 60
    hours = mins / 60
    return "#{hours}h" if hours < 24
    days = hours / 24
    return "#{days}d" if days < 30
    "#{days / 30}mo"
  end
end
