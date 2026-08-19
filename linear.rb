require "net/http"
require "json"
require "uri"

# Read-only Linear client.
#
# Three joins are possible between a pull request and an issue, in descending
# order of trust:
#
#   1. a Linear attachment whose url is the pull request  -- authoritative,
#      created by Linear's own GitHub integration
#   2. UBI-123 in the branch name, title or body          -- the convention
#   3. nothing                                            -- today's normal case
#
# Measured when this was written: 0 of the last 100 pull requests carried a
# reference, and the workspace had 0 agent sessions. So every caller must read
# well with no data at all, and simply get richer as the team adopts it.
class Linear
  ENDPOINT = "https://api.linear.app/graphql".freeze
  ISSUE_RE = /\b([A-Z][A-Z0-9]+)-(\d+)\b/

  class Error < StandardError; end

  def initialize(api_key:, http: nil, ttl: 300)
    @api_key = api_key.to_s
    @http = http
    @ttl = ttl
    @cache = {}
    @lock = Mutex.new
    raise Error, "missing Linear API key" if @api_key.empty?
  end

  def configured? = !@api_key.empty?

  # Everyone in the workspace, so a user can say which one is them.
  def users = cached(:users) { query(USERS_Q).dig("users", "nodes") || [] }

  def teams = cached(:teams) { query(TEAMS_Q).dig("teams", "nodes") || [] }

  # Open issues, optionally narrowed to one assignee id.
  def open_issues(assignee_id: nil)
    cached([:open_issues, assignee_id]) do
      vars = {assigneeId: assignee_id}
      (query(assignee_id ? MY_ISSUES_Q : OPEN_ISSUES_Q, vars).dig("issues", "nodes") || [])
        .map { |n| normalise(n) }
    end
  end

  # pull request url => issue, from Linear's own attachments. This is the join
  # that needs no convention from anybody.
  def issues_by_pull_request
    cached(:by_pr) do
      nodes = query(ATTACHMENTS_Q).dig("attachments", "nodes") || []
      nodes.each_with_object({}) do |a, h|
        url = a["url"].to_s
        next unless url.include?("/pull/")
        next unless (issue = a["issue"])
        h[canonical_pr(url)] = normalise(issue)
      end
    end
  end

  # Identifiers mentioned in a branch, title or body: the convention route.
  def self.referenced_identifier(*texts)
    texts.compact.join(" ").upcase[ISSUE_RE, 0]
  end

  def issues_by_identifier(identifiers)
    ids = Array(identifiers).map(&:to_s).map(&:upcase).uniq.reject(&:empty?)
    return {} if ids.empty?

    cached([:by_ident, ids.sort]) do
      numbers = ids.filter_map { |i| i.split("-").last.to_i if i.include?("-") }.uniq
      nodes = query(BY_NUMBER_Q, {numbers: numbers}).dig("issues", "nodes") || []
      nodes.each_with_object({}) do |n, h|
        issue = normalise(n)
        h[issue[:identifier]] = issue if ids.include?(issue[:identifier])
      end
    end
  end

  # "https://github.com/o/r/pull/123?x=1" -> "o/r#123", so both join routes and
  # the queue's own row key line up.
  def canonical_pr(url)
    m = url.to_s.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
    m ? "#{m[1]}/#{m[2]}##{m[3]}" : url.to_s
  end

  private

  def normalise(n)
    {identifier: n["identifier"], title: n["title"], url: n["url"],
     state: n.dig("state", "name"), state_type: n.dig("state", "type"),
     assignee: n.dig("assignee", "displayName"),
     labels: (n.dig("labels", "nodes") || []).map { |l| l["name"] },
     priority: n["priority"], updated_at: n["updatedAt"]}
  end

  def cached(key)
    @lock.synchronize do
      hit = @cache[key]
      return hit[:value] if hit && (Time.now - hit[:at]) < @ttl
    end
    value = yield
    @lock.synchronize { @cache[key] = {value: value, at: Time.now} }
    value
  end

  def query(graphql, variables = {})
    body = JSON.generate(query: graphql, variables: variables.compact)
    return @http.call(body) if @http

    uri = URI(ENDPOINT)
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = @api_key
    req["Content-Type"] = "application/json"
    req["User-Agent"] = "review-queue"
    req.body = body
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
      http.request(req)
    end
    parsed = begin
      JSON.parse(res.body.to_s)
    rescue JSON::ParserError
      raise Error, "Linear returned a non-JSON response (#{res.code})"
    end
    raise Error, "Linear: #{parsed["errors"].first["message"]}" if parsed["errors"]
    parsed["data"] || {}
  end

  ISSUE_FIELDS = <<~GQL
    identifier title url priority updatedAt
    state { name type }
    assignee { displayName }
    labels(first: 5) { nodes { name } }
  GQL

  USERS_Q = "{ users(first: 100, filter: {active: {eq: true}}) { nodes { id name displayName email } } }"
  TEAMS_Q = "{ teams(first: 20) { nodes { id key name } } }"
  OPEN_ISSUES_Q = "{ issues(first: 100, filter: {state: {type: {nin: [\"completed\",\"canceled\"]}}}, " \
                  "orderBy: updatedAt) { nodes { #{ISSUE_FIELDS} } } }"
  MY_ISSUES_Q = "query($assigneeId: ID) { issues(first: 100, filter: {assignee: {id: {eq: $assigneeId}}, " \
                "state: {type: {nin: [\"completed\",\"canceled\"]}}}, orderBy: updatedAt) { nodes { #{ISSUE_FIELDS} } } }"
  ATTACHMENTS_Q = "{ attachments(first: 250) { nodes { url issue { #{ISSUE_FIELDS} } } } }"
  BY_NUMBER_Q = "query($numbers: [Float!]) { issues(first: 100, filter: {number: {in: $numbers}}) " \
                "{ nodes { #{ISSUE_FIELDS} } } }"
end
