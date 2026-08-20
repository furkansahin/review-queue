require "net/http"
require "json"
require "uri"
require "time"

class GitHubClient
  API = "https://api.github.com"

  # Connections are pooled and reused across requests.
  #
  # A rebuild makes about six calls per pull request, and Net::HTTP.start per
  # call paid for a fresh TCP connection and TLS handshake every time --
  # measured against api.github.com at ~130 ms of the ~390 ms a call took, so
  # a 25-pull-request queue threw away roughly twenty seconds of handshake.
  #
  # The pool is a free list rather than a thread-local, because the fetch
  # spawns a new set of threads for every pull request: a thread-local
  # connection would be built and dropped again after a single request. A
  # thread takes a connection for the length of one request and returns it.
  MAX_IDLE = 16

  attr_reader :rate_remaining

  def initialize(token)
    @token = token
    @mutex = Mutex.new
    @idle = Hash.new { |h, k| h[k] = [] }
  end

  def get(path)
    uri = URI(path.start_with?("http") ? path : API + path)
    res = request(uri)
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

  # Closes every idle connection. Nothing depends on this in the app -- the
  # sockets go when the process does -- but a test can leave the machine tidy.
  def close_idle
    taken = @mutex.synchronize { @idle.values.flatten.tap { @idle.clear } }
    taken.each { |http| finish(http) }
  end

  private

  # An idle keep-alive connection can be closed by the far end at any moment,
  # and that only shows up as an error on the next write. Retry those exactly
  # once, on a fresh connection. A timeout is not retried: it has already spent
  # the caller's time once.
  DROPPED = [EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, Net::HTTPBadResponse].freeze

  def request(uri)
    fresh = false
    begin
      http = take(uri, fresh: fresh)
      begin
        res = http.request(build_request(uri))
      rescue StandardError
        finish(http)
        raise
      end
      keep(uri, http)
      res
    rescue *DROPPED
      raise if fresh
      fresh = true
      retry
    end
  end

  def build_request(uri)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["User-Agent"] = "review-queue"
    req
  end

  def key_for(uri) = "#{uri.hostname}:#{uri.port}"

  def take(uri, fresh: false)
    unless fresh
      http = @mutex.synchronize { @idle[key_for(uri)].pop }
      return http if http&.started?
    end
    connect(uri)
  end

  def connect(uri)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 25
    http.keep_alive_timeout = 30
    http.start
    http
  end

  # Capped, so a wide fan-out cannot leave dozens of sockets open afterwards.
  # Closing happens outside the lock: it is I/O, and nothing else needs to wait
  # for it.
  def keep(uri, http)
    kept = @mutex.synchronize do
      list = @idle[key_for(uri)]
      list.size < MAX_IDLE && http.started? && list.push(http)
    end
    finish(http) unless kept
  end

  def finish(http)
    http.finish if http&.started?
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
    @label = self.class.clean_label(label)
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

  # Only " and \ can break out of the quoted search term. Commas and spaces are
  # legal in a GitHub label, so they stay. Strip last: removing a character can
  # leave whitespace at either end, and so can the length cap.
  def self.clean_label(value)
    value.to_s.delete('"').delete("\\").strip[0, 64].to_s.strip
  end

  def watch_label? = !@label.empty?

  def buckets
    list = [
      {key: :review, label: "Review requested", q: "#{@scope} is:open is:pr review-requested:@me"},
      {key: :mention, label: "Mentions me", q: "#{@scope} is:open is:pr mentions:@me"}
    ]
    if watch_label?
      list << {key: :label, label: @label, q: %(#{@scope} is:open is:pr label:"#{@label}")}
    end
    list << {key: :mine, label: "My PRs", q: "#{@scope} is:open is:pr author:@me"}
    list
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
    # /user and the bucket searches do not depend on one another -- the search
    # queries say `@me` and GitHub expands it -- so they go together. Fetching
    # the login first put one whole round trip in front of every rebuild.
    #
    # threaded turns a failure into nil, which for the login would mean quietly
    # building the queue for nobody, so this one keeps its exception and raises
    # it after the wave. snapshot turns that into the error the page shows.
    failure = nil
    tasks = [-> {
      begin
        @gh.get("/user").fetch("login")
      rescue StandardError => e
        failure = e
        nil
      end
    }]
    tasks += buckets.map { |b|
      -> {
        res = @gh.get("/search/issues?per_page=#{@per_page}&sort=updated&q=#{URI.encode_www_form_component(b[:q])}")
        [b[:key], res["items"] || []]
      }
    }
    login, *found = threaded(tasks, &:call)
    raise failure if failure
    raise "GitHub did not say who is signed in" if login.nil?

    entries = {}
    found.each do |result|
      key, items = result
      next unless items
      items.each do |item|
        e = entries[item["html_url"]] ||= {item: item, buckets: []}
        e[:buckets] << key
      end
    end

    # The weekly count reads the events feed, which nothing else here depends
    # on, so it runs alongside the per-pull-request fetch. It used to be up to
    # three more serial round trips tacked onto the end of every rebuild.
    weekly = Thread.new { reviews_this_week(login) }

    prs = threaded(entries.values) { |entry| detail(entry, login) }.compact
    rows = prs.map { |pr| row(pr, login) }.sort_by { |r| r[:sort_key] }

    {rows: rows, login: login, fetched_at: Time.now, rate: @gh.rate_remaining, error: nil,
     counts: counts(rows), reviews_7d: weekly.value}
  end

  # Pull requests you reviewed in the last 7 days.
  #
  # This must NOT come from the queue. GitHub removes you from the requested
  # reviewers as soon as you submit a review, and a reviewed pull request is
  # usually merged soon after. So a reviewed pull request leaves the queue
  # almost immediately, and counting inside the queue returns close to zero
  # every time. The public events feed holds the real review events instead,
  # with their own timestamps, and it still sees closed pull requests.
  #
  # Cost is one extra API call for each rebuild. The feed holds public events
  # only, which is sufficient because RQ_SCOPE must be public repos anyway.
  # Returns {count:, complete:}. complete is false when the pages we read did
  # not reach back past the cutoff, so the count is a floor, not a total.
  # Returns nil when the feed cannot be read, and then the page shows nothing.
  MAX_EVENT_PAGES = 3

  def reviews_this_week(login, now: Time.now)
    cutoff = now - (7 * 86_400)
    seen = {}
    oldest = nil
    read_any = false

    (1..MAX_EVENT_PAGES).each do |page|
      events = @gh.try("/users/#{login}/events/public?per_page=100&page=#{page}")
      break unless events.is_a?(Array)
      read_any = true
      break if events.empty?

      events.each do |e|
        at = begin
          Time.parse(e["created_at"].to_s)
        rescue StandardError
          next
        end
        oldest = at if oldest.nil? || at < oldest
        next unless e["type"] == "PullRequestReviewEvent"
        next if at < cutoff
        repo = e.dig("repo", "name")
        next unless in_scope?(repo)
        number = e.dig("payload", "pull_request", "number")
        seen["#{repo}##{number}"] = true
      end
      break if oldest && oldest < cutoff
    end

    return nil unless read_any
    {count: seen.size, complete: !!(oldest && oldest < cutoff)}
  end

  # RQ_SCOPE is a GitHub search fragment. Read the repositories and the owners
  # out of it, so the event feed can be limited to the same repositories.
  def scope_repos
    @scope_repos ||= @scope.scan(%r{repo:([\w.\-]+/[\w.\-]+)}i).flatten.map(&:downcase)
  end

  def scope_owners
    @scope_owners ||= @scope.scan(/(?:org|user|owner):([\w.\-]+)/i).flatten.map(&:downcase)
  end

  def in_scope?(full_name)
    return false unless full_name
    name = full_name.downcase
    return true if scope_repos.include?(name)
    return true if scope_owners.include?(name.split("/").first)
    scope_repos.empty? && scope_owners.empty?
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

    # For a pull request you own, "who spoke last" is the wrong question. The
    # right one is whether anybody still owes you a review. GitHub keeps that
    # as current state: it removes a reviewer from requested_reviewers when
    # they submit, and puts them back when you re-request.
    awaiting_review = !((pull["requested_reviewers"] || []).empty? &&
                        (pull["requested_teams"] || []).empty?)

    # One approval is enough to hand the ball back to the author: they can
    # merge. Count only each reviewer's LATEST review, and only if it is not
    # older than the head commit -- an approval of code that has since been
    # replaced does not mean the pull request is ready.
    latest_by_reviewer = {}
    (reviews || []).each do |r|
      next if r["submitted_at"].nil?
      who = r.dig("user", "login")
      at = Time.parse(r["submitted_at"])
      next if r["state"] == "PENDING"
      cur = latest_by_reviewer[who]
      latest_by_reviewer[who] = {state: r["state"], at: at} if cur.nil? || at >= cur[:at]
    end
    approved = latest_by_reviewer.any? { |_, r| r[:state] == "APPROVED" && r[:at] >= commit_at }

    {
      url: item["html_url"], title: item["title"], number: n, repo: repo, owner: owner,
      author: pull.dig("user", "login") || "?", draft: !!pull["draft"], ci: ci,
      labels: (item["labels"] || []).map { |l| l["name"] },
      buckets: entry[:buckets],
      mine: pull.dig("user", "login") == login,
      last: last, my_last: my_last, last_other: last_other,
      i_acted: !!(my_last && last && my_last[:at] >= last[:at]),
      awaiting_review: awaiting_review, approved: approved,
      changed: pull["changed_files"], churn: (pull["additions"].to_i + pull["deletions"].to_i)
    }
  end

  def row(pr, login)
    # settled means "nothing here for me". It drives the state word, the sort
    # order, Hide settled, and the progress bar, so it must carry the whole
    # decision and not only the label.
    settled =
      if pr[:mine]
        # Waiting on them only while somebody is actually on the hook and has
        # not already approved.
        pr[:awaiting_review] && !pr[:approved]
      else
        pr[:i_acted]
      end
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
      # repo is the bare name ("ubicloud"), which is what the row shows.
      # repo_full is "owner/name", which is what GitHub, the job records and
      # the dev box all need. The key uses the full name so a row and its job
      # identify the same pull request.
      key: "#{pr[:owner]}/#{pr[:repo]}##{pr[:number]}",
      repo: pr[:repo], repo_full: "#{pr[:owner]}/#{pr[:repo]}", number: pr[:number],
      last_at: pr.dig(:last, :at),
      buckets: pr[:buckets] + (quick ? [:quick] : []), settled: settled,
      # Reddest first: oldest wait_from means most days waiting, which is what
      # age_colors ramps red. Settled rows ("Reviewed" / "Waiting on them") are
      # grey regardless of age, so they sink below everything. A row with no
      # timeline events reads as fresh, so it sorts last within its group.
      # 0 act on it, 1 draft (listed, but not today), 2 settled.
      sort_key: [settled ? 2 : (pr[:draft] ? 1 : 0), wait_from ? wait_from.to_i : Float::INFINITY],
      draft: pr[:draft],
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
