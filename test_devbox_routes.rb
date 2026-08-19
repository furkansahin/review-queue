#!/usr/bin/env ruby
# Dev box page tests:  DATABASE_URL=... bundle exec ruby test_devbox_routes.rb
ENV["DATABASE_URL"]          ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]       = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
require "rack/test"
require_relative "app"

WHO = {login: "furkansahin"}
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => WHO[:login]} } }
QueueService.class_eval do
  define_method(:snapshot) do |force: false|
    {rows: [], counts: counts([]), login: WHO[:login], fetched_at: Time.now, rate: 5000,
     error: nil, reviews_7d: {count: 0, complete: true}}
  end
end
PING = {ok: false, output: "", error: "unreachable"}
DevBox.singleton_class.prepend(Module.new do
  def run(_box, cmd, timeout: 30) = cmd == "ping" ? PING : {ok: true, output: ""}
end)

include Rack::Test::Methods
def app = ReviewQueue.app
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,24], want.inspect[0,24])
end
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

DB.exec("TRUNCATE review_jobs, dev_boxes RESTART IDENTITY CASCADE")
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

get "/devbox"
check("page renders with no box yet", last_response.status, 200)
check("offers registration", last_response.body.include?("Register this dev box"), true)
check("no key shown before registering", last_response.body.include?("authorized_keys"), false)

tok = csrf_for(last_response.body, "/devbox/save")
post "/devbox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22", "_csrf" => tok}
row = DB.row("SELECT * FROM dev_boxes WHERE login = $1", ["furkansahin"])
check("box saved", row["host"], "203.0.113.10")
check("a keypair was generated", row["public_key"].start_with?("ssh-rsa "), true)
check("private key is encrypted at rest", row["private_key_enc"].include?("BEGIN"), false)
check("private key decrypts to a PEM", Crypto.decrypt(row["private_key_enc"]).start_with?("-----BEGIN"), true)

get "/devbox"
check("shows the forced-command line", last_response.body.include?('command=&quot;/usr/local/bin/rq-review&quot;,restrict'), true)
check("shows the public key", last_response.body.include?(row["public_key"][0, 40]), true)
check("never shows the private key", last_response.body.include?("BEGIN RSA"), false)
check("shows the wrapper install command", last_response.body.include?("/usr/local/bin/rq-review"), true)

# editing the address must not churn the key
before = row["public_key"]
tok = csrf_for(last_response.body, "/devbox/save")
post "/devbox/save", {"host" => "10.0.0.9", "ssh_user" => "ubi", "port" => "2222", "_csrf" => tok}
after = DB.row("SELECT * FROM dev_boxes WHERE login = $1", ["furkansahin"])
check("address updated", [after["host"], after["port"]], ["10.0.0.9", 2222])
check("key kept when only the address changes", after["public_key"], before)

# validation
get "/devbox"; tok = csrf_for(last_response.body, "/devbox/save")
post "/devbox/save", {"host" => "1.2.3.4; rm -rf /", "ssh_user" => "ubi", "port" => "22", "_csrf" => tok}
check("shell metacharacters in host refused",
      DB.row("SELECT host FROM dev_boxes WHERE login=$1", ["furkansahin"])["host"], "10.0.0.9")
get "/devbox"
check("error is shown to the user", last_response.body.include?("host name or IP"), true)
post "/devbox/save", {"host" => "ok.example.com", "ssh_user" => "ubi", "port" => "99999",
                      "_csrf" => csrf_for(last_response.body, "/devbox/save")}
check("out-of-range port refused",
      DB.row("SELECT port FROM dev_boxes WHERE login=$1", ["furkansahin"])["port"], 2222)

# test connection records the failure
get "/devbox"; post "/devbox/test", {"_csrf" => csrf_for(last_response.body, "/devbox/test")}
check("failed test is recorded", DB.row("SELECT last_error FROM dev_boxes WHERE login=$1", ["furkansahin"])["last_error"], "unreachable")
get "/devbox"
check("failure is shown", last_response.body.include?("unreachable"), true)

# rotation replaces the key
old_pub = DB.row("SELECT public_key FROM dev_boxes WHERE login=$1", ["furkansahin"])["public_key"]
post "/devbox/rotate", {"_csrf" => csrf_for(last_response.body, "/devbox/rotate")}
check("rotate issues a new key", DB.row("SELECT public_key FROM dev_boxes WHERE login=$1", ["furkansahin"])["public_key"] == old_pub, false)

# CSRF everywhere
post "/devbox/save", {"host" => "evil", "ssh_user" => "x", "port" => "22"}
check("save without CSRF blocked", last_response.status, 403)
post "/devbox/delete", {}
check("delete without CSRF blocked", last_response.status, 403)

# another user cannot see or touch mine
WHO[:login] = "mohi-kalantari"
o = Rack::Test::Session.new(Rack::MockSession.new(app))
o.get "/auth/start"; st2 = o.last_response.location[/state=([^&]+)/, 1]
o.get "/auth/callback?code=c&state=#{st2}"
o.get "/devbox"
check("another user sees no box", o.last_response.body.include?("10.0.0.9"), false)
o.post "/devbox/delete", {"_csrf" => csrf_for(o.last_response.body, "/devbox/delete")}
check("their delete cannot remove mine",
      DB.row("SELECT count(*)::int n FROM dev_boxes WHERE login=$1", ["furkansahin"])["n"], 1)

# removal really deletes the key
WHO[:login] = "furkansahin"
get "/devbox"; post "/devbox/delete", {"_csrf" => csrf_for(last_response.body, "/devbox/delete")}
check("remove deletes the row and its key", DB.row("SELECT count(*)::int n FROM dev_boxes")["n"], 0)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
