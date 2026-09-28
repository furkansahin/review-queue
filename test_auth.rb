#!/usr/bin/env ruby
# Route-level auth tests:  bundle exec ruby test_auth.rb
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]      = "furkansahin, Alice"
ENV["RQ_GITHUB_CLIENT_ID"]    = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"]= "csecret"
ENV["RQ_BASE_URL"]            = "https://review.example.com"
ENV["RQ_SESSION_SECRET"]      = "a" * 64
ENV["RQ_INSECURE_COOKIES"]    = "1"   # test client is plain http
ENV["RQ_REDIRECT_HOSTS"]      = "old.example.com, review.example.com"

require "rack/test"
require_relative "app"

# --- stub GitHub -------------------------------------------------------------
STUB = {token: "gho_stubtoken", login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |code| code == "goodcode" ? STUB[:token] : raise("bad verification code") } }
GitHubClient.class_eval do
  define_method(:get) do |path|
    return {"login" => STUB[:login]} if path == "/user"
    raise "unexpected #{path}"
  end
end
QueueService.class_eval { define_method(:snapshot) { |force: false| {rows: [], counts: {}, login: STUB[:login], fetched_at: Time.now, rate: 5000, error: nil, reviews_7d: {count: 0, complete: true}} } }

include Rack::Test::Methods
def app = ReviewQueue.freeze.app

results = []
def check(results, name, cond, detail = "")
  results << [name, cond]
  puts format("  %s  %-46s %s", cond ? "ok  " : "FAIL", name, detail)
end

# 1. healthz stays public
get "/healthz"
check(results, "GET /healthz public", last_response.status == 200 && last_response.body == "ok")

# 1b. an old name forwards to the main one, and nothing else does
get "/sessions/changes?id=4", {}, "HTTP_HOST" => "old.example.com"
check(results, "an old name forwards, path and query kept",
      last_response.status == 301 && last_response.location == "https://review.example.com/sessions/changes?id=4",
      last_response.location.to_s)
post "/snooze", {"key" => "o/r#1"}, "HTTP_HOST" => "OLD.example.com:443"
check(results, "a POST keeps its method on the way", last_response.status == 308, last_response.status.to_s)
get "/healthz", {}, "HTTP_HOST" => "10.0.0.5:5000"
check(results, "the health check is not forwarded", last_response.status == 200 && last_response.body == "ok")
get "/login", {}, "HTTP_HOST" => "review.example.com"
check(results, "nor is the main name, even when listed", last_response.status == 200)

# 2. root redirects to login when signed out
get "/"
check(results, "GET / signed out -> /login", last_response.status == 302 && last_response.location == "/login")

# 3. login page renders
get "/login"
check(results, "GET /login renders", last_response.status == 200 && last_response.body.include?("Sign in with GitHub"))
check(results, "under the app's name and mark", last_response.body.include?("<h1>Leeghwater</h1>") &&
                                                  last_response.body.include?(Logo::OUTLINE))
check(results, "with the tab icon", last_response.body.include?('<link rel="icon" href="/favicon.svg"'))

# 3b. the tab icon is public: the sign-in page asks for it too
get "/favicon.svg"
check(results, "GET /favicon.svg public", last_response.status == 200 &&
                                           last_response.headers["Content-Type"].to_s.start_with?("image/svg+xml"))
check(results, "the empty drop, for both themes", last_response.body.include?(Logo::WATER) &&
                                                   last_response.body.include?("prefers-color-scheme:dark"))
get "/logo.png"
check(results, "and as a PNG, for places that take no SVG", last_response.status == 200 &&
      last_response.headers["Content-Type"] == "image/png" && last_response.body.b.start_with?("\x89PNG".b))

# 4. /auth/start sets state and redirects to GitHub with scope=
get "/auth/start"
loc = last_response.location.to_s
state = loc[/state=([^&]+)/, 1]
check(results, "auth/start -> github authorize", last_response.status == 302 && loc.start_with?("https://github.com/login/oauth/authorize"))
check(results, "authorize requests NO scopes", loc.include?("scope=&") || loc.end_with?("scope="), loc[/scope=[^&]*/].to_s)

# 5. callback with a forged/mismatched state is rejected
get "/auth/callback?code=goodcode&state=forged"
check(results, "callback rejects bad state (CSRF)", last_response.body.include?("tampered"))

# 6. still signed out after the forged attempt
get "/"
check(results, "forged state did not sign in", last_response.location == "/login")

# 7. real flow
get "/auth/start"
state = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=goodcode&state=#{state}"
check(results, "valid callback signs in", last_response.status == 302 && last_response.location == "/")
get "/"
check(results, "GET / now renders queue", last_response.status == 200 && last_response.body.include?(">Leeghwater</span>"))
check(results, "with the mark in its header", last_response.body.include?(Logo::OUTLINE))

# 8. allowlist denies a non-listed login
STUB[:login] = "randomstranger"
get "/auth/start"; state = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=goodcode&state=#{state}"
check(results, "allowlist blocks stranger", last_response.body.include?("allowlist"))

# 9. allowlist is case-insensitive
STUB[:login] = "ALICE"
get "/auth/start"; state = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=goodcode&state=#{state}"
check(results, "allowlist case-insensitive (ALICE)", last_response.location == "/")

# 10. CSRF is enforced on refresh
post "/refresh"
check(results, "POST /refresh without CSRF blocked", last_response.status >= 400, "status #{last_response.status}")

# 11. bad code surfaces an error rather than signing in
get "/auth/start"; state = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=WRONG&state=#{state}"
check(results, "bad code -> error, not signed in", last_response.body.include?("GitHub sign-in failed"))

puts
puts(results.all? { |_, c| c } ? "ALL PASS (#{results.size})" : "FAILURES: #{results.reject { |_,c| c }.map(&:first).join(', ')}")
