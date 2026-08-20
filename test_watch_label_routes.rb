#!/usr/bin/env ruby
# Watch label route tests:  bundle exec ruby test_watch_label_routes.rb
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_LABEL"]                = "clickhouse"   # a hint only; must NOT be applied

require "rack/test"
require_relative "app"

WHO = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_#{WHO[:login]}" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WHO[:login]} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: WHO[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: {count: 0, complete: true}}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-50s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect, want.inspect)
end
def tabs(body) = body.scan(/class="tab[^"]*" href="\/\?tab=([a-z]+)/).flatten
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

def sign_in
  get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
  get "/auth/callback?code=c&state=#{st}"
end

sign_in
get "/"
check("new user gets NO label tab despite RQ_LABEL", tabs(last_response.body).include?("label"), false)
check("input shows RQ_LABEL only as a placeholder",
      last_response.body.include?('placeholder="clickhouse"'), true)
check("input value is empty for a new user",
      last_response.body[/id="label" name="label" value="([^"]*)"/, 1], "")

# set a label
tok = csrf_for(last_response.body, "/settings")
post "/settings", {"label" => "clickhouse", "_csrf" => tok}
check("settings redirects", last_response.status, 302)
get "/"
check("label tab appears after opting in", tabs(last_response.body).include?("label"), true)
check("input keeps the chosen label",
      last_response.body[/id="label" name="label" value="([^"]*)"/, 1], "clickhouse")

# clearing it removes the bucket again
tok = csrf_for(last_response.body, "/settings")
post "/settings", {"label" => "", "_csrf" => tok}
get "/"
check("empty submit removes the label tab", tabs(last_response.body).include?("label"), false)

# CSRF is enforced
post "/settings", {"label" => "sneaky"}
check("settings without CSRF is blocked", last_response.status, 403)

# a second user in a separate session must not inherit anything
tok = csrf_for((get "/"; last_response.body), "/settings")
post "/settings", {"label" => "clickhouse", "_csrf" => tok}
other = Rack::Test::Session.new(Rack::MockSession.new(app))
WHO[:login] = "mohi-kalantari"
other.get "/auth/start"; st2 = other.last_response.location[/state=([^&]+)/, 1]
other.get "/auth/callback?code=c&state=#{st2}"
other.get "/"
check("second user does not inherit the first's label",
      tabs(other.last_response.body).include?("label"), false)
WHO[:login] = "furkansahin"
get "/"
check("first user still has their label", tabs(last_response.body).include?("label"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
