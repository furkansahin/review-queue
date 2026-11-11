#!/usr/bin/env ruby
# Tearing down every box at once:  bundle exec ruby test_wipe.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"
ENV["RQ_SCOPE"]                = "repo:ubicloud/ubicloud"

require "rack/test"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
def add_box(login, host)
  DB.row(<<~SQL, [login, host])
    INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key)
    VALUES ($1, $2, 'ubi', 22, 'x', 'ssh-ed25519 AAAA') RETURNING *
  SQL
end
mine = add_box("furkansahin", "203.0.113.10")
theirs = add_box("mohi-kalantari", "203.0.113.20")

# A baybox per login: what each one has, and what was torn down where.
class FakeRunner
  attr_accessor :boxes, :refuse, :list_error, :leftovers, :sweep_error
  attr_reader :torn, :forgot, :kept

  def initialize
    @boxes = {}
    @torn = []
    @forgot = 0
    @refuse = {}
    @leftovers = []
  end

  def list(box)
    return {ok: false, output: "", error: @list_error} if @list_error
    {ok: true, output: @boxes.fetch(box["login"], []).map { |n| "#{n}\treview/x\tbox\n" }.join}
  end

  def teardown(box, name)
    return {ok: false, output: "", error: @refuse[name]} if @refuse[name]
    @torn << [box["login"], name]
    @boxes[box["login"]].delete(name)
    {ok: true, output: ""}
  end

  def forget_box_list(_box) = @forgot += 1

  def sweep(_box, keep:)
    @kept = keep
    return {ok: false, output: "", error: @sweep_error} if @sweep_error
    gone = @leftovers - keep
    @leftovers -= gone
    {ok: true, output: "", boxes: gone}
  end
end

puts "-- the worker, one box a tick --"
fake = FakeRunner.new
fake.boxes = {"furkansahin" => %w[rq-ubicloud-ubicloud-1 rq-ubicloud-ubicloud-2 rq-ubicloud-ubicloud-3],
              "mohi-kalantari" => %w[rq-ubicloud-ubicloud-9]}
job = DB.row(<<~SQL, [mine["id"]])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state)
  VALUES ('furkansahin', $1, 'ubicloud/ubicloud', 2, 'rq-ubicloud-ubicloud-2', 'running') RETURNING id
SQL
Wipe.tick(runner: fake)
check("nothing asked, nothing torn down", fake.torn, [])
Wipe.request("furkansahin")
check("asked: the page says it is under way", Wipe.status("furkansahin")[:running], true)
Wipe.tick(runner: fake)
check("one box on the first tick", fake.torn, [["furkansahin", "rq-ubicloud-ubicloud-1"]])
check("how far it has got", Wipe.status("furkansahin").values_at(:done, :left), [1, 2])
fake.boxes["furkansahin"] << "rq-ubicloud-ubicloud-7"   # a review started after the button
Wipe.tick(runner: fake)
row = DB.row("SELECT state, error, torn_down_at FROM review_jobs WHERE id = $1", [job["id"]])
check("a running review in a box torn down is settled", [row["state"], row["error"], !row["torn_down_at"].nil?],
      ["failed", "the box was torn down", true])
Wipe.tick(runner: fake)
Wipe.tick(runner: fake)
check("every box it found, and only mine", fake.torn.map(&:last), %w[rq-ubicloud-ubicloud-1 rq-ubicloud-ubicloud-2 rq-ubicloud-ubicloud-3])
check("a box started after the button stays", fake.boxes["furkansahin"], %w[rq-ubicloud-ubicloud-7])
check("someone else's box is never touched", fake.boxes["mohi-kalantari"], %w[rq-ubicloud-ubicloud-9])
check("over, and says so", Wipe.status("furkansahin").values_at(:running, :note), [false, "Tore down all 3 boxes."])
check("the leftovers spared: what is listed, and what has a job", fake.kept.sort, %w[rq-ubicloud-ubicloud-7])
check("the cached box list is dropped each time", fake.forgot, 3)
Wipe.tick(runner: fake)
check("nothing more once it is over", fake.torn.size, 3)

puts "-- what older boxes left in Docker --"
fake.boxes["furkansahin"] = %w[rq-ubicloud-ubicloud-8]
fake.leftovers = %w[rq-ubicloud-ubicloud-6209 rq-ubicloud-ubicloud-6632 rq-ubicloud-ubicloud-7]
DB.exec(<<~SQL, [mine["id"]])
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state)
  VALUES ('furkansahin', $1, 'ubicloud/ubicloud', 7, 'rq-ubicloud-ubicloud-7', 'queued')
SQL
Wipe.request("furkansahin")
3.times { Wipe.tick(runner: fake) }
check("cleared, and named", Wipe.status("furkansahin")[:note],
      "Tore down your one box. Also cleared what 2 older boxes left behind in Docker: rq-ubicloud-ubicloud-6209, rq-ubicloud-ubicloud-6632.")
check("but not a box a review is queued for", fake.leftovers, %w[rq-ubicloud-ubicloud-7])
fake.sweep_error = "ssh: connect to host 203.0.113.10 port 22: Connection refused"
Wipe.request("furkansahin")
3.times { Wipe.tick(runner: fake) }
check("a sweep that fails says so", Wipe.status("furkansahin")[:note],
      "There were no boxes to tear down. Could not clear what older boxes left behind: ssh: connect to host 203.0.113.10 port 22: Connection refused")
fake.sweep_error = nil
fake.leftovers = []
DB.exec("DELETE FROM review_jobs WHERE box_name = 'rq-ubicloud-ubicloud-7'")

puts "-- a box that will not go --"
fake.boxes["furkansahin"] = %w[rq-a rq-b]
fake.refuse = {"rq-a" => "box \"rq-a\" has uncommitted changes in its worktree"}
Wipe.request("furkansahin")
4.times { Wipe.tick(runner: fake) }
check("the others still go", fake.boxes["furkansahin"], %w[rq-a])
check("and it is named, with why", Wipe.status("furkansahin")[:note],
      "Tore down 1 of 2 boxes. These would not go: rq-a: box \"rq-a\" has uncommitted changes in its worktree")
fake.refuse = {}

puts "-- a baybox that cannot be listed --"
fake.list_error = "ssh: connect to host 203.0.113.10 port 22: Connection timed out"
Wipe.request("furkansahin")
Wipe.tick(runner: fake)
check("stops, and says why", Wipe.status("furkansahin").values_at(:running, :note),
      [false, "Could not tear down your boxes: the baybox could not be listed (ssh: connect to host 203.0.113.10 port 22: Connection timed out)."])
fake.list_error = nil

puts "-- through the page --"
include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_session" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
LISTED = [%w[rq-ubicloud-ubicloud-1 review/pr-1 box], %w[rq-ubicloud-ubicloud-2 review/pr-2 box]]
Runner.singleton_class.prepend(Module.new { def box_list(_) = LISTED.dup })
DB.exec("UPDATE bayboxes SET wipe_note = NULL")
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"
get "/sessions"
page = last_response.body
check("a button for all of them", page.include?(">Tear down all</button>"), true)
check("which asks first, with how many", page.include?("Tear down all 2 boxes?"), true)
tok = page[%r{action="/sessions/teardown-all"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1]
post "/sessions/teardown-all", {"_csrf" => tok}
check("asked, back to the page", last_response.location.to_s.end_with?("/sessions"), true)
check("for me", Wipe.status("furkansahin")[:running], true)
check("not for anyone else", Wipe.status("mohi-kalantari")[:running], false)
get "/sessions"
page = last_response.body
check("while it runs: a line, not the button", [page.include?("Tearing down all your boxes, one at a time"),
                                               page.include?(">Tear down all</button>")], [true, false])
check("and the page follows it", page.include?("location.reload()"), true)
fake.boxes["furkansahin"] = %w[rq-ubicloud-ubicloud-1 rq-ubicloud-ubicloud-2]
Wipe.tick(runner: fake)
check("how far it has got, on the page", (get("/sessions"); last_response.body.include?("1 gone, 1 to go")), true)
2.times { Wipe.tick(runner: fake) }
check("the result, once", (get("/sessions"); last_response.body.include?("Tore down all 2 boxes.")), true)
check("and not again", (get("/sessions"); last_response.body.include?("Tore down all 2 boxes.")), false)
LISTED.pop
check("no button for a single box: its own is right there", (get("/sessions"); last_response.body.include?(">Tear down all</button>")), false)
post "/sessions/teardown-all", {}
check("refused without the form's token", Wipe.status("furkansahin")[:running], false)

puts "-- forgetting the torn-down list --"
DB.exec("ALTER TABLE voice_examples DROP CONSTRAINT IF EXISTS voice_examples_job_id_fkey")
DB.exec("ALTER TABLE voice_examples ADD CONSTRAINT voice_examples_job_id_fkey " \
        "FOREIGN KEY (job_id) REFERENCES review_jobs(id) ON DELETE CASCADE")
DB.setup!
check("a database from before no longer cascades", DB.row(
  "SELECT confdeltype FROM pg_constraint WHERE conname = 'voice_examples_job_id_fkey'")["confdeltype"], "n")
DB.exec("DELETE FROM review_jobs")
def gone_job(login, baybox, n, draft_at: nil, learned: false)
  draft = draft_at && JSON.generate("at" => draft_at.utc.iso8601, "review_id" => 1)
  DB.row(<<~SQL, [login, baybox["id"], n, "rq-ubicloud-ubicloud-#{n}", draft, learned ? Time.now : nil])["id"]
    INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, torn_down_at, draft_json, learned_at)
    VALUES ($1, $2, 'ubicloud/ubicloud', $3, $4, 'done', now(), $5, $6) RETURNING id
  SQL
end
plain   = gone_job("furkansahin", mine, 101)
learned = gone_job("furkansahin", mine, 102, draft_at: Time.now - 86_400, learned: true)
pending = gone_job("furkansahin", mine, 103, draft_at: Time.now - 86_400)
stale   = gone_job("furkansahin", mine, 104, draft_at: Time.now - 30 * 86_400)
other   = gone_job("mohi-kalantari", theirs, 105)
live = DB.row(<<~SQL, [mine["id"]])["id"]
  INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state)
  VALUES ('furkansahin', $1, 'ubicloud/ubicloud', 106, 'rq-ubicloud-ubicloud-106', 'done') RETURNING id
SQL
DB.exec(<<~SQL, [learned])
  INSERT INTO voice_examples (login, job_id, repo, pr_number, kind, drafted, posted)
  VALUES ('furkansahin', $1, 'ubicloud/ubicloud', 102, 'rewritten', 'drafted words', 'my words')
SQL
get "/sessions"
page = last_response.body
check("a button by the torn-down list", page.include?(">Forget all</button>"), true)
check("which asks first, with how many", page.include?("Forget all 4 torn-down reviews?"), true)
tok = page[%r{action="/sessions/forget-all"[^>]*>\s*<input type="hidden" name="_csrf" value="([^"]+)"}m, 1]
post "/sessions/forget-all", {"_csrf" => tok}
left = DB.rows("SELECT id FROM review_jobs ORDER BY id").map { |r| r["id"] }
check("gone: the torn-down ones", (left & [plain, learned, stale]), [])
check("kept: a draft still pending on GitHub, to learn from", left.include?(pending), true)
check("kept: a review whose box is still there", left.include?(live), true)
check("kept: someone else's", left.include?(other), true)
ex = DB.row("SELECT posted, job_id FROM voice_examples")
check("what was learned from one stays", [ex && ex["posted"], ex && ex["job_id"]], ["my words", nil])
get "/sessions"
check("says what it did, and why one stayed", last_response.body.include?(
  "Forgot 3 torn-down reviews. Kept 1: its draft is still pending on GitHub, and what you change before submitting is learned from."), true)
post "/sessions/forget-all", {}
check("refused without the form's token", DB.row("SELECT count(*) AS n FROM review_jobs")["n"].to_i, 3)

DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
