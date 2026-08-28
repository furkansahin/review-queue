#!/usr/bin/env ruby
# Sign-in redirect tests:  bundle exec ruby test_redirect_loop.rb
#
# A session holding a login but no token used to bounce between / and /login
# for ever: / sends you to /login when the token is missing, and /login sent
# you back to / because a login was present. The browser gave up with
# ERR_TOO_MANY_REDIRECTS and the only way out was deleting cookies.
#
# The re-sign-in path makes exactly that state -- it drops a dead token before
# sending you to GitHub -- so any GitHub round trip that does not finish lands
# you in it.
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:5432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_REAUTH_GRACE"]         = "1"
require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

WORLD = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WORLD[:login]} } }
DEAD = {yes: false}
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: WORLD[:login], fetched_at: Time.now, rate: 5000,
     error: DEAD[:yes] ? "GitHub 401" : nil, unauthorized: DEAD[:yes], reviews_7d: nil}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app

# Follow redirects by hand, so a loop is a count rather than a hang.
def hops(session, path, limit: 12)
  seen = []
  limit.times do
    session.get(path)
    break unless session.last_response.status == 302
    path = session.last_response.headers["location"] || session.last_response.headers["Location"]
    seen << path
  end
  seen
end

def sign_in(session)
  session.get "/auth/start"
  st = session.last_response.location[/state=([^&]+)/, 1]
  session.get "/auth/callback?code=c&state=#{st}"
end

puts "-- a session with a login but no token --"
# Reached the way a person reaches it: the stored token dies, the queue sends
# them to sign in again and drops the dead token on the way, and the GitHub
# round trip does not finish.
sign_in(self)
sleep 2.2                       # older than RQ_REAUTH_GRACE, set to 1 below
DEAD[:yes] = true
REGISTRY.forget("furkansahin")
get "/"
check("a dead token sends them to sign in again", last_response.headers["location"], "/auth/start")
DEAD[:yes] = false              # they never finish it; the token is already gone
trail = hops(self, "/")
check("it settles instead of bouncing", trail.size < 12, true)
check("and it settles on the sign-in page", trail.last, "/login")
get "/login"
check("which actually renders", last_response.status, 200)
check("and offers a way back in", last_response.body.downcase.include?("sign in"), true)

puts "-- a full session still goes where it should --"
sign_in(self)
get "/login"
check("signed in, /login sends you to the queue", last_response.headers["location"], "/")
get "/"
check("and the queue renders", last_response.status, 200)

puts "-- a session with neither --"
o = Rack::Test::Session.new(Rack::MockSession.new(app))
trail = hops(o, "/")
check("goes to the sign-in and stops", trail, ["/login"])

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
