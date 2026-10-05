#!/usr/bin/env ruby
# Learning how a person writes reviews from what they post:  bundle exec ruby test_voice.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_SCOPE"]                = "repo:ubicloud/ubicloud"
require "tmpdir"
ENV["RQ_BAY_ROOT"]             = Dir.mktmpdir("rq-voice")

require "rack/test"
require_relative "app"
require_relative "worker"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

REPO = "ubicloud/ubicloud"
BASE = "/repos/#{REPO}/pulls/6577"
$routes = {}
$calls = []
def answer(token, verb, path, body = nil)
  $calls << [token, verb, path, body]
  v = $routes.fetch([verb, path]) { raise %(GitHub 404 on #{path}: {"message":"Not Found"}) }
  raise v if v.is_a?(String)
  v
end
GitHubClient.class_eval do
  define_method(:get) { |path| path == "/user" && $routes.empty? ? {"login" => "furkansahin"} : answer(@token, :get, path) }
  define_method(:post) { |path, body| answer(@token, :post, path, body) }
end

# #6577, as it went: four comments drafted, two posted in a sentence or two,
# two dropped, the summary deleted.
D_PG = {path: "prog/postgres/postgres_resource_nexus.rb", line: 363, side: "RIGHT",
        body: "I don't think the 15 day branch can be reached, even with 47 day certs. " + ("The 47 day cert is the ACME one. " * 10) +
              "\n\nverified — added a debug line and ran a public resource."}
D_UTIL = {path: "lib/util.rb", line: 43, side: "RIGHT", body: "let's narrow this to `rescue OpenSSL::X509::CertificateError`. " + ("Swallowing everything is not free. " * 8)}
D_SPEC = {path: "spec/model/cert_spec.rb", line: 57, side: "RIGHT", body: "these don't pin the 60 day cutoff."}
D_CACHE = {path: "migrate/20261002_cert_expires_at.rb", line: 6, side: "RIGHT", body: "cache/schema.cache ended up in the next commit."}
P_PG = "I don't think we can ever reach the 15 day path here considering this check is specifically pulling `client_cert`."
P_UTIL = "We already check `if cert` in `before_save`, is this rescue necessary here?"
def posted(id, path, line, body, user: "furkansahin")
  {"pull_request_review_id" => id, "path" => path, "original_line" => line, "side" => "RIGHT", "body" => body, "user" => {"login" => user}}
end

puts "-- pairing --"
pairs, dropped, added = Voice.pair([D_PG, D_UTIL, D_SPEC],
                                   [{path: D_PG[:path], line: 363, side: "RIGHT", body: P_PG},
                                    {path: "lib/util.rb", line: 45, side: "RIGHT", body: P_UTIL},
                                    {path: "model/cert.rb", line: 9, side: "RIGHT", body: "mine"}])
check("the same line pairs", pairs.first.map { |c| c[:body][0, 10] }, [D_PG[:body][0, 10], P_PG[0, 10]])
check("so does one a couple of lines off", pairs.size, 2)
check("a drafted comment with nothing posted near it is dropped", dropped, [D_SPEC])
check("a posted one with nothing drafted is theirs", added.map { |c| c[:body] }, ["mine"])
check("whitespace is not a rewrite", Voice.same?("a  b\n", "a b"), true)

puts "-- learning from the submitted review --"
DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
DB.exec("DELETE FROM user_settings")
box = DB.row(<<~SQL, [Crypto.encrypt("github_pat_READ"), Crypto.encrypt("github_pat_WRITE")])
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key, github_token_enc, github_write_token_enc)
  VALUES ('furkansahin', '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA', $1, $2) RETURNING *
SQL
job = DB.row(<<~SQL, [box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, finished_at)
  VALUES ('furkansahin', $1, $2, 6577, 'rq-ubicloud-ubicloud-6577', 'done', 'review', now()) RETURNING *
SQL
Voice.record_draft(job["id"], review_id: 777, at: Time.now - 600, summary: "The expires_at column is sound. " * 5,
                   sent: [D_PG, D_UTIL, D_SPEC, D_CACHE], unticked: [])
$routes = {[:get, "#{BASE}/reviews/777"] => {"id" => 777, "state" => "PENDING", "body" => ""}}
Voice.tick
check("still pending: nothing learned yet", DB.row("SELECT learned_at FROM review_jobs")["learned_at"], nil)
check("read with the box's read token", $calls.map(&:first).uniq, ["github_pat_READ"])
$calls.clear
Voice.tick
check("and not asked again for five minutes", $calls.size, 0)

DB.exec("UPDATE review_jobs SET learn_checked_at = NULL")
$routes = {[:get, "#{BASE}/reviews/777"] => {"id" => 777, "state" => "COMMENTED", "body" => ""},
           [:get, "#{BASE}/comments?per_page=100&page=1"] => [
             posted(777, D_PG[:path], 363, P_PG), posted(777, "lib/util.rb", 43, P_UTIL),
             posted(555, "lib/util.rb", 43, "someone else's review", user: "jeremyevans")]}
Voice.tick
j = DB.row("SELECT learned_at, learn_note FROM review_jobs")
check("submitted: learned", j["learned_at"].nil?, false)
check("saying what", j["learn_note"], "learned from your submitted review: 2 rewritten, 2 dropped, summary dropped")
kinds = DB.rows("SELECT kind, drafted, posted FROM voice_examples ORDER BY id")
check("each comment in its place", kinds.map { |k| k["kind"] }, %w[rewritten rewritten dropped dropped summary])
check("with their own words", kinds.first["posted"], P_PG)
check("and nobody else's", kinds.any? { |k| k["posted"].to_s.include?("someone else") }, false)

# Edited on the draft page, then posted as edited: still the box's words
# against theirs.
job3 = DB.row(<<~SQL, [box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, finished_at)
  VALUES ('furkansahin', $1, $2, 6590, 'rq-ubicloud-ubicloud-6590', 'done', 'review', now()) RETURNING *
SQL
Voice.record_draft(job3["id"], review_id: 444, at: Time.now - 600, summary: "",
                   sent: [D_SPEC.merge(path: "e.rb", body: "Pin the cutoff?", original: D_SPEC[:body])], unticked: [])
$routes = {[:get, "/repos/#{REPO}/pulls/6590/reviews/444"] => {"id" => 444, "state" => "COMMENTED", "body" => ""},
           [:get, "/repos/#{REPO}/pulls/6590/comments?per_page=100&page=1"] => [posted(444, "e.rb", 57, "Pin the cutoff?")]}
Voice.tick
ex = DB.row("SELECT kind, drafted, posted FROM voice_examples WHERE job_id = $1", [job3["id"]])
check("an edit on the page is learned as a rewrite of the box's words", ex.values_at("kind", "drafted", "posted"),
      ["rewritten", D_SPEC[:body], "Pin the cutoff?"])

puts "-- a draft thrown away for a review of their own --"
job2 = DB.row(<<~SQL, [box["id"], REPO])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, kind, finished_at)
  VALUES ('furkansahin', $1, $2, 6563, 'rq-ubicloud-ubicloud-6563', 'done', 'review', now()) RETURNING *
SQL
Voice.record_draft(job2["id"], review_id: 888, at: Time.now - 600, summary: "", sent: [D_SPEC.merge(path: "a.rb")],
                   unticked: [D_CACHE.merge(path: "b.rb")])
B2 = "/repos/#{REPO}/pulls/6563"
$routes = {[:get, "#{B2}/reviews?per_page=100"] => [
             {"id" => 1, "state" => "COMMENTED", "user" => {"login" => "furkansahin"}, "submitted_at" => (Time.now - 86_400).utc.iso8601},
             {"id" => 999, "state" => "CHANGES_REQUESTED", "user" => {"login" => "furkansahin"}, "submitted_at" => Time.now.utc.iso8601, "body" => ""}],
           [:get, "#{B2}/comments?per_page=100&page=1"] => [posted(999, "c.rb", 3, "Needs a down migration.")]}
Voice.tick
check("learned from the review they wrote instead",
      DB.row("SELECT learn_note FROM review_jobs WHERE id = $1", [job2["id"]])["learn_note"],
      "learned from your submitted review: 2 dropped, 1 added by you")
check("an unticked comment counts as dropped", DB.rows("SELECT drafted FROM voice_examples WHERE job_id = $1 AND kind = 'dropped'", [job2["id"]]).size, 2)

puts "-- their recent comments --"
$routes = {[:get, "/repos/#{REPO}/pulls/comments?sort=created&direction=desc&per_page=100&page=1"] =>
             (1..20).map { |i| posted(i, "f#{i}.rb", i, "comment #{i}", user: i.even? ? "furkansahin" : "jeremyevans")
                                  .merge("pull_request_url" => "https://api.github.com/repos/#{REPO}/pulls/#{6000 + i}",
                                         "created_at" => "2026-10-0#{1 + (i % 5)}T10:00:#{format("%02d", i)}Z") }}
check("their own, nobody else's", Voice.refresh_own(GitHubClient.new("t"), "furkansahin"), 10)
check("kept", DB.rows("SELECT posted FROM voice_examples WHERE kind = 'own'").map { |r| r["posted"] }.all? { |p| p.match?(/comment \d*[02468]\z/) }, true)
check("and not read again today", DB.rows(<<~SQL).size, 0)
  SELECT 1 FROM user_settings WHERE login = 'furkansahin' AND (voice_own_at IS NULL OR voice_own_at < now() - interval '20 hours')
SQL

puts "-- what a review is given --"
check("their notes come first", Voice.save_notes("furkansahin", "One or two sentences. Ask, do not assert."), nil)
text = Voice.compose("furkansahin")
check("the notes", text.include?("## In their own words\n\nOne or two sentences. Ask, do not assert."), true)
check("ahead of the examples", text.index("In their own words") < text.index("## Rewritten"), true)
check("the numbers: how much they post", text.include?("Of 7 comments drafted for them, they posted 3"), true)
check("and how long", text.match?(/Their comments run about \d+ words; the drafts ran about \d+/), true)
check("and the summaries", text.include?("1 of 1 drafted summaries were deleted"), true)
check("each rewrite, drafted then theirs", text.include?("They wrote:\n> #{P_PG}"), true)
check("what they added", text.include?("> Needs a down migration."), true)
check("what they dropped", text.include?("> these don't pin the 60 day cutoff."), true)
check("their recent comments", text.include?("## Their recent comments"), true)
check("never past the cap", Voice.compose("furkansahin").length <= Voice::MAX_FILE + 20, true)
check("nothing known, nothing given", Voice.compose("mohi-kalantari"), nil)
check("notes have a limit", Voice.save_notes("furkansahin", "x" * 2001).to_s.include?("over 2000"), true)

puts "-- the worker hands it to the review --"
write_voice({"login" => "furkansahin", "box_name" => "rq-ubicloud-ubicloud-6600"})
path = File.join(Runner.state_dir("furkansahin", "rq-ubicloud-ubicloud-6600"), "voice.md")
check("written where the review picks it up", File.read(path).include?("One or two sentences."), true)
write_voice({"login" => "mohi-kalantari", "box_name" => "rq-ubicloud-ubicloud-6600"})
check("(another person's run in that place has none)", File.exist?(File.join(Runner.state_dir("mohi-kalantari", "rq-ubicloud-ubicloud-6600"), "voice.md")), false)

puts "-- through the app --"
include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
$routes = {}
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/baybox"
page = last_response.body
check("the Baybox page shows the voice", page.include?("Review voice") && page.include?("Ask, do not assert."), true)
check("and what a review is given", page.include?("what a review is given"), true)
tok = ->(path) { last_response.body[%r{action="#{Regexp.escape(path)}"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1] }
post "/baybox/voice", {"notes" => "Short. No evidence.", "_csrf" => tok.("/baybox/voice")}
check("notes are saved", Voice.notes("furkansahin"), "Short. No evidence.")
get "/baybox"
post "/baybox/voice/read", {"_csrf" => tok.("/baybox/voice/read")}
check("read now: the worker reads them on its next minute", DB.row("SELECT voice_own_at FROM user_settings WHERE login = 'furkansahin'")["voice_own_at"], nil)
get "/baybox"
post "/baybox/voice/forget", {"_csrf" => tok.("/baybox/voice/forget")}
check("forget: the examples go", Voice.counts("furkansahin"), {})
check("your own notes stay", Voice.notes("furkansahin"), "Short. No evidence.")

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
