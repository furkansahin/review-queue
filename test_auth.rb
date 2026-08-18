#!/usr/bin/env ruby
# Route-level auth tests:  bundle exec ruby test_auth.rb
ENV["RQ_ALLOWED_LOGINS"]      = "furkansahin, Alice"
ENV["RQ_GITHUB_CLIENT_ID"]    = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"]= "csecret"
ENV["RQ_BASE_URL"]            = "https://review.furkansahin.work"
ENV["RQ_SESSION_SECRET"]      = "a" * 64
ENV["RQ_INSECURE_COOKIES"]    = "1"   # test client is plain http

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
QueueService.class_eval { define_method(:snapshot) { |force: false| {rows: [], counts: {}, login: STUB[:login], fetched_at: Time.now, rate: 5000, error: nil, reviews_7d: 0} } }

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

# 2. root redirects to login when signed out
get "/"
check(results, "GET / signed out -> /login", last_response.status == 302 && last_response.location == "/login")

# 3. login page renders
get "/login"
check(results, "GET /login renders", last_response.status == 200 && last_response.body.include?("Sign in with GitHub"))

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
check(results, "GET / now renders queue", last_response.status == 200 && last_response.body.include?("Review queue"))

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
