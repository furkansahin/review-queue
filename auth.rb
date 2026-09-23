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
  Entry = Struct.new(:service, :token, :label, :last_used, :first_seen)

  # store: where each person's last queue is kept between restarts
  # (QueueStore), or nil to keep nothing.
  def initialize(idle_ttl:, max_users:, store: nil, **service_opts)
    @idle_ttl = idle_ttl
    @max_users = max_users
    @store = store
    @service_opts = service_opts
    @entries = {}
    @lock = Mutex.new
  end

  # label is the user's own watched label, so it is passed for each request
  # and not baked into the shared options.
  def for(login, token, label: "")
    label = QueueService.clean_label(label)
    @lock.synchronize do
      sweep
      entry = @entries[login]
      # A fresh sign-in issues a new token, and changing the watched label
      # changes the search queries. Either one needs a new service, because the
      # cached snapshot no longer answers the right question.
      if entry.nil? || entry.token != token || entry.label != label
        service = QueueService.new(token: token, label: label, saved: @store&.for(login), **@service_opts)
        # first_seen carries across a new token or a changed label: those make
        # a new service, not a new person at the keyboard.
        entry = Entry.new(service, token, label, nil, entry&.first_seen || Time.now)
        @entries[login] = entry
      end
      entry.last_used = Time.now
      evict_extras
      entry.service
    end
  end

  # Who is signed in, for the people page. Read-only, and nothing it returns
  # holds a token: the point of the registry is that a token stays in the one
  # place it is used.
  #
  # This is less than it sounds. One web process, in memory, emptied by a
  # deploy, swept after idle_ttl. So it answers "who has used the queue
  # recently", not "who has ever signed in", and the page says so.
  def active(now: Time.now)
    @lock.synchronize do
      sweep
      @entries.map { |login, e|
        {login: login, label: e.label.to_s,
         idle_for: e.last_used ? (now - e.last_used).to_i : nil,
         signed_in_for: e.first_seen ? (now - e.first_seen).to_i : nil}
      }.sort_by { |u| u[:idle_for] || 0 }
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
