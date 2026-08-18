require "net/http"
require "json"
require "uri"
require "securerandom"

# GitHub OAuth web flow, requesting *no scopes*.
#
# A scopeless token still resolves GET /user (needed to expand `@me` in the
# search queries) and still gets the 5000/hr authenticated rate limit, but it
# cannot write anything anywhere. That is strictly less privilege than a
# fine-grained PAT, and it is only sufficient because RQ_SCOPE covers public
# repos -- adding a private repo would require the (write-granting) `repo`
# scope, at which point this choice needs revisiting.
class GitHubOAuth
  AUTHORIZE = "https://github.com/login/oauth/authorize"
  TOKEN = "https://github.com/login/oauth/access_token"

  def initialize(client_id:, client_secret:, redirect_uri:)
    @client_id = client_id
    @client_secret = client_secret
    @redirect_uri = redirect_uri
  end

  def authorize_url(state)
    params = {client_id: @client_id, redirect_uri: @redirect_uri, state: state, scope: ""}
    "#{AUTHORIZE}?#{URI.encode_www_form(params)}"
  end

  # Exchanges the callback code for a user access token. Raises on failure.
  def exchange(code)
    uri = URI(TOKEN)
    req = Net::HTTP::Post.new(uri)
    req["Accept"] = "application/json"
    req["User-Agent"] = "review-queue"
    req.set_form_data(client_id: @client_id, client_secret: @client_secret,
      code: code, redirect_uri: @redirect_uri)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
      http.request(req)
    end
    raise "GitHub token exchange failed (#{res.code})" unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    # GitHub answers 200 with an error body when the code is bad or replayed.
    raise "GitHub token exchange failed: #{body["error_description"] || body["error"]}" if body["error"]

    token = body["access_token"]
    raise "GitHub token exchange returned no access_token" unless token && !token.empty?
    token
  end
end

# One QueueService per signed-in user, so each fetches with their own token and
# keeps their own TTL cache. Evicts on idle and caps total users, since every
# live entry holds a snapshot in memory and a rebuild fans out worker threads.
class ServiceRegistry
  Entry = Struct.new(:service, :token, :last_used)

  def initialize(idle_ttl:, max_users:, **service_opts)
    @idle_ttl = idle_ttl
    @max_users = max_users
    @service_opts = service_opts
    @entries = {}
    @lock = Mutex.new
  end

  def for(login, token)
    @lock.synchronize do
      sweep
      entry = @entries[login]
      # A fresh sign-in issues a new token; drop the stale service with it.
      if entry.nil? || entry.token != token
        entry = Entry.new(QueueService.new(token: token, **@service_opts), token, nil)
        @entries[login] = entry
      end
      entry.last_used = Time.now
      evict_extras
      entry.service
    end
  end

  def forget(login)
    @lock.synchronize { @entries.delete(login) }
  end

  def size
    @lock.synchronize { @entries.size }
  end

  private

  def sweep
    cutoff = Time.now - @idle_ttl
    @entries.delete_if { |_, e| e.last_used && e.last_used < cutoff }
  end

  # Oldest-idle-first, so the cap can never be exceeded even without idle churn.
  def evict_extras
    return if @entries.size <= @max_users
    ordered = @entries.sort_by { |_, e| e.last_used || Time.at(0) }
    ordered.first(@entries.size - @max_users).each { |login, _| @entries.delete(login) }
  end
end
