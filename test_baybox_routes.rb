#!/usr/bin/env ruby
# Baybox page tests:  DATABASE_URL=... bundle exec ruby test_baybox_routes.rb
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
require_relative "runner"

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
# Both transports, so the test holds whichever one the app is built with.
box_stub = Module.new do
  def run(_box, cmd, timeout: 30, stdin: nil) = cmd.to_s.start_with?("ping") ? PING : {ok: true, output: ""}
  def check(box_row) = run(box_row, "ping")
  def box_list(_box_row) = []
  def forget_box_list(_box_row) = nil
end
BayBox.singleton_class.prepend(box_stub)
Runner.singleton_class.prepend(box_stub)

include Rack::Test::Methods
def app = ReviewQueue.app
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,24], want.inspect[0,24])
end
def csrf_for(body, path) = body[/action="#{Regexp.escape(path)}[^"]*"[^>]*>\s*<input type="hidden" name="[^"]+" value="([^"]+)"/m, 1]

DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

get "/baybox"
check("page renders with no box yet", last_response.status, 200)
check("offers registration", last_response.body.include?("Register this baybox"), true)
check("no key shown before registering", last_response.body.include?("authorized_keys"), false)

tok = csrf_for(last_response.body, "/baybox/save")
post "/baybox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22", "_csrf" => tok}
row = DB.row("SELECT * FROM bayboxes WHERE login = $1", ["furkansahin"])
check("box saved", row["host"], "203.0.113.10")
check("a keypair was generated", row["public_key"].start_with?("ssh-rsa "), true)
check("private key is encrypted at rest", row["private_key_enc"].include?("BEGIN"), false)
check("private key decrypts to a PEM", Crypto.decrypt(row["private_key_enc"]).start_with?("-----BEGIN"), true)

get "/baybox"
# bay needs git and docker over this connection, so the key logs in. restrict
# is what survives the move: no forwarding, no pty, none of which bay uses.
check("the key line is restricted", last_response.body.include?("restrict ssh-rsa"), true)
check("but not pinned to the old wrapper",
      last_response.body.include?('command=&quot;/usr/local/bin/rq-review&quot;'), false)
check("shows the public key", last_response.body.include?(row["public_key"][0, 40]), true)
check("never shows the private key", last_response.body.include?("BEGIN RSA"), false)
# Anyone whose box predates the migration has a pinned line that must go, so
# the page names it. Checked by the name, not by the sentence around it.
check("and says which old line to remove",
      last_response.body.include?("/usr/local/bin/rq-review"), true)

# Each field says how to get its value, because the answer is a command or a
# page somewhere else and nobody should have to go looking.
check("the claude token says where it comes from",
      last_response.body.include?("claude setup-token"), true)
check("the github token links to where you make one",
      last_response.body.include?("github.com/settings/personal-access-tokens"), true)
check("and names the access it needs",
      last_response.body.include?("Contents: Read"), true)
check("and the repository it needs it on",
      last_response.body.include?("ubicloud/ubicloud"), true)
check("the skills field says what shape a skills repo is",
      last_response.body.include?("SKILL.md"), true)

# editing the address must not churn the key
before = row["public_key"]
tok = csrf_for(last_response.body, "/baybox/save")
post "/baybox/save", {"host" => "10.0.0.9", "ssh_user" => "ubi", "port" => "2222", "_csrf" => tok}
after = DB.row("SELECT * FROM bayboxes WHERE login = $1", ["furkansahin"])
check("address updated", [after["host"], after["port"]], ["10.0.0.9", 2222])
check("key kept when only the address changes", after["public_key"], before)

# validation
get "/baybox"; tok = csrf_for(last_response.body, "/baybox/save")
post "/baybox/save", {"host" => "1.2.3.4; rm -rf /", "ssh_user" => "ubi", "port" => "22", "_csrf" => tok}
check("shell metacharacters in host refused",
      DB.row("SELECT host FROM bayboxes WHERE login=$1", ["furkansahin"])["host"], "10.0.0.9")
get "/baybox"
check("error is shown to the user", last_response.body.include?("host name or IP"), true)
post "/baybox/save", {"host" => "ok.example.com", "ssh_user" => "ubi", "port" => "99999",
                      "_csrf" => csrf_for(last_response.body, "/baybox/save")}
check("out-of-range port refused",
      DB.row("SELECT port FROM bayboxes WHERE login=$1", ["furkansahin"])["port"], 2222)

# test connection records the failure
get "/baybox"; post "/baybox/test", {"_csrf" => csrf_for(last_response.body, "/baybox/test")}
check("failed test is recorded", DB.row("SELECT last_error FROM bayboxes WHERE login=$1", ["furkansahin"])["last_error"], "unreachable")
get "/baybox"
check("failure is shown", last_response.body.include?("unreachable"), true)

# --- the tokens bay needs, now that it runs on the dashboard -----------------
post "/baybox/save", {"host" => "203.0.113.10", "ssh_user" => "ubi", "port" => "22",
                      "claude_token" => "sk-ant-oat01-SECRET", "github_token" => "github_pat_SECRET",
                      "repo_path" => "ubicloud",
                      "_csrf" => csrf_for(last_response.body, "/baybox/save")}
row = DB.row("SELECT * FROM bayboxes WHERE login=$1", ["furkansahin"])
check("the claude token is encrypted at rest", row["claude_token_enc"].include?("SECRET"), false)
check("and decrypts back", Crypto.decrypt(row["claude_token_enc"]), "sk-ant-oat01-SECRET")
check("the github token too", Crypto.decrypt(row["github_token_enc"]), "github_pat_SECRET")
check("the repo path is stored", row["repo_path"], "ubicloud")

get "/baybox"
check("no token is ever shown back", last_response.body.include?("SECRET"), false)
check("the page says one is stored", last_response.body.include?("stored — leave blank"), true)

# Blank means keep. Otherwise changing the host would clear both tokens, which
# is a silent way to break every future review.
post "/baybox/save", {"host" => "203.0.113.11", "ssh_user" => "ubi", "port" => "22",
                      "claude_token" => "", "github_token" => "", "repo_path" => "ubicloud",
                      "_csrf" => csrf_for(last_response.body, "/baybox/save")}
row = DB.row("SELECT * FROM bayboxes WHERE login=$1", ["furkansahin"])
check("a blank field keeps the stored token", Crypto.decrypt(row["claude_token_enc"]), "sk-ant-oat01-SECRET")
check("while the host did change", row["host"], "203.0.113.11")

get "/baybox"
post "/baybox/save", {"host" => "203.0.113.11", "ssh_user" => "ubi", "port" => "22",
                      "claude_token" => "-", "repo_path" => "ubicloud",
                      "_csrf" => csrf_for(last_response.body, "/baybox/save")}
check("a dash clears it",
      DB.row("SELECT claude_token_enc FROM bayboxes WHERE login=$1", ["furkansahin"])["claude_token_enc"], nil)

get "/baybox"
post "/baybox/save", {"host" => "203.0.113.11", "ssh_user" => "ubi", "port" => "22",
                      "repo_path" => "../../etc",
                      "_csrf" => csrf_for(last_response.body, "/baybox/save")}
check("a traversing repo path is refused",
      DB.row("SELECT repo_path FROM bayboxes WHERE login=$1", ["furkansahin"])["repo_path"], "ubicloud")

get "/baybox"   # the next CSRF token comes from a rendered form, not a redirect

# --- preparing a box -----------------------------------------------------
# The key is the one step that cannot be automated: it is what grants the
# access everything else needs. Docker and the checkout are just commands.
PREPARED = {ok: true, output: "  docker already installed\n  cloned into ~/ubicloud\n  ready\n"}
[BayBox, Runner].each do |mod|
  mod.singleton_class.prepend(Module.new do
    define_method(:prepare_box) { |_row| PREPARED }
  end)
end

get "/baybox"
check("the page offers to prepare the box", last_response.body.include?("Prepare this box"), true)
post "/baybox/prepare", {"_csrf" => csrf_for(last_response.body, "/baybox/prepare")}
get "/baybox"
check("and that it finished", last_response.body.include?("Prepared the box"), true)
# The output goes to the database, not the session: it runs to over a thousand
# bytes and the session is a 4 KB cookie shared with the sign-in and the snooze
# list. What is left in the flash has to stay small.
notice = last_response.body[/Prepared the box[^<]*/].to_s
check("the message is bounded", notice.length <= 220, true)
check("a success clears any previous failure",
      DB.row("SELECT last_error FROM bayboxes WHERE login=$1", ["furkansahin"])["last_error"], nil)

PREPARED.replace(ok: false, output: "", error: "sudo needs a password")
get "/baybox"
post "/baybox/prepare", {"_csrf" => csrf_for(last_response.body, "/baybox/prepare")}
get "/baybox"
check("a failure is reported, not swallowed", last_response.body.include?("sudo needs a password"), true)
# ...and the whole of it is kept where the page prints it, rather than in the
# cookie, which is what made the site unusable until cookies were cleared.
check("the detail is stored on the row",
      DB.row("SELECT last_error FROM bayboxes WHERE login=$1", ["furkansahin"])["last_error"].to_s.include?("sudo needs a password"), true)
check("and it is not called a success",
      last_response.body.include?("Prepared the box"), false)

get "/baybox"
check("the button says it will take a while",
      last_response.body.include?("Preparing…"), true)
check("and disables itself, so it is not pressed twice",
      last_response.body.include?("b.disabled=true"), true)

post "/baybox/prepare", {}
check("preparing without CSRF blocked", last_response.status, 403)
PREPARED.replace(ok: true, output: "  ready\n")

get "/baybox"   # the next CSRF token comes from a rendered form, not a redirect

# rotation replaces the key
old_pub = DB.row("SELECT public_key FROM bayboxes WHERE login=$1", ["furkansahin"])["public_key"]
post "/baybox/rotate", {"_csrf" => csrf_for(last_response.body, "/baybox/rotate")}
check("rotate issues a new key", DB.row("SELECT public_key FROM bayboxes WHERE login=$1", ["furkansahin"])["public_key"] == old_pub, false)

# CSRF everywhere
post "/baybox/save", {"host" => "evil", "ssh_user" => "x", "port" => "22"}
check("save without CSRF blocked", last_response.status, 403)
post "/baybox/delete", {}
check("delete without CSRF blocked", last_response.status, 403)

# another user cannot see or touch mine
WHO[:login] = "mohi-kalantari"
o = Rack::Test::Session.new(Rack::MockSession.new(app))
o.get "/auth/start"; st2 = o.last_response.location[/state=([^&]+)/, 1]
o.get "/auth/callback?code=c&state=#{st2}"
o.get "/baybox"
check("another user sees no box", o.last_response.body.include?("10.0.0.9"), false)

# Give this user their own box first. With no box their page shows no delete
# form. The delete then fails on CSRF, and a CSRF failure tells you nothing
# about the login scope. The delete must reach the route to be a real test.
o.post "/baybox/save", {"host" => "198.51.100.5", "ssh_user" => "ubi", "port" => "22",
                        "_csrf" => csrf_for(o.last_response.body, "/baybox/save")}
check("their box saved",
      DB.row("SELECT host FROM bayboxes WHERE login=$1", ["mohi-kalantari"])["host"], "198.51.100.5")
o.get "/baybox"
o.post "/baybox/delete", {"_csrf" => csrf_for(o.last_response.body, "/baybox/delete")}
check("their delete passes CSRF", o.last_response.status == 403, false)
check("their delete removes their box",
      DB.row("SELECT count(*)::int n FROM bayboxes WHERE login=$1", ["mohi-kalantari"])["n"], 0)
check("their delete cannot remove mine",
      DB.row("SELECT count(*)::int n FROM bayboxes WHERE login=$1", ["furkansahin"])["n"], 1)

# removal really deletes the key
WHO[:login] = "furkansahin"
get "/baybox"; post "/baybox/delete", {"_csrf" => csrf_for(last_response.body, "/baybox/delete")}
check("remove deletes the row and its key", DB.row("SELECT count(*)::int n FROM bayboxes")["n"], 0)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
