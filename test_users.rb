#!/usr/bin/env ruby
# People page tests:  bundle exec ruby test_users.rb
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:5432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari,jeremyevans"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end

WHO = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_#{WHO[:login]}" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WHO[:login]} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: WHO[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: nil}
  end
end

include Rack::Test::Methods
def app = ReviewQueue.app
def sign_in(s = self)
  s.get "/auth/start"
  st = s.last_response.location[/state=([^&]+)/, 1]
  s.get "/auth/callback?code=c&state=#{st}"
end

DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
priv, pub = BayBox.generate_keypair
box = DB.row(<<~SQL, ["jeremyevans", "10.0.0.9", "ubi", 22, Crypto.encrypt(priv), pub])
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key)
  VALUES ($1,$2,$3,$4,$5,$6) RETURNING *
SQL
2.times do |i|
  DB.exec(<<~SQL, ["jeremyevans", box["id"], "ubicloud/ubicloud", 100 + i, "rq-x-#{100 + i}"])
    INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state)
    VALUES ($1,$2,$3,$4,$5,'done')
  SQL
end

puts "-- it needs a sign-in, like every other page --"
o = Rack::Test::Session.new(Rack::MockSession.new(app))
o.get "/users"
check("a stranger is sent to sign in", o.last_response.headers["location"], "/login")

puts "-- everyone on the allowlist is listed --"
sign_in
get "/users"
body = last_response.body
check("the page renders", last_response.status, 200)
%w[furkansahin mohi-kalantari jeremyevans].each do |who|
  check("#{who} is listed", body.include?(who), true)
end
# The header is class="row head", so it is not one of these.
check("and nobody else is", body.scan(/class="row"/).size, 3)

puts "-- it says who is here now --"
check("the signed-in user is marked", body.include?("(you)"), true)
check("and counted", body.include?("<strong>1</strong>"), true)
# Someone who has never loaded the queue is still listed, because "who has not
# started" is the useful half of the answer.
check("someone who never signed in still appears", body.include?("jeremyevans"), true)

puts "-- what each person has done comes from the database --"
check("a registered baybox is shown", body.include?("10.0.0.9"), true)
check("so is their review count", body.include?(">2<") || body.match?(/\b2\b/), true)
check("and someone without a box says so", body.include?("no baybox"), true)

puts "-- a token never reaches the page --"
# The registry holds one per signed-in user. This page is the one that walks it.
check("no github token in the html", body.include?("gho_"), false)
check("nor any encrypted material", body.include?(Crypto.encrypt("x")[0, 6]), false)
check("nor a private key", body.include?("BEGIN"), false)

puts "-- a second person shows up as a second person --"
WHO[:login] = "mohi-kalantari"
two = Rack::Test::Session.new(Rack::MockSession.new(app))
sign_in(two)
two.get "/"          # the queue is what registers them
two.get "/users"
check("both are signed in now", two.last_response.body.include?("<strong>2</strong>"), true)
WHO[:login] = "furkansahin"

puts "-- the registry is what it claims, and no more --"
# It is one process's memory: swept after idle_ttl, emptied by a restart. The
# page says so, because a number that looks authoritative and is not is worse
# than no number.
check("the page explains the limit", body.include?("deploy resets it"), true)
check("and names the window", body.include?("#{REGISTRY_IDLE_TTL / 60} minutes"), true)

puts "-- forgetting a user takes them off it --"
REGISTRY.forget("mohi-kalantari")
get "/users"
check("they are no longer counted here", last_response.body.include?("<strong>1</strong>"), true)
check("but they are still listed", last_response.body.include?("mohi-kalantari"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
