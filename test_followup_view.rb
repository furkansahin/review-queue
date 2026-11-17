#!/usr/bin/env ruby
# The review stays readable through its follow-ups:  bundle exec ruby test_followup_view.rb
ENV["DATABASE_URL"]            ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"]        = "0" * 64
ENV["RQ_ALLOWED_LOGINS"]       = "furkansahin,mohi-kalantari"
ENV["RQ_GITHUB_CLIENT_ID"]     = "cid"
ENV["RQ_GITHUB_CLIENT_SECRET"] = "csecret"
ENV["RQ_BASE_URL"]             = "http://example.com"
ENV["RQ_SESSION_SECRET"]       = "a" * 64
ENV["RQ_INSECURE_COOKIES"]     = "1"

require "rack/test"
require "json"
require_relative "app"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-60s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

def ev(h) = JSON.generate(h) + "\n"
def tool(cmd) = ev(type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: cmd}}]})
def result(text) = ev(type: "result", subtype: "success", is_error: false, duration_ms: 9000, num_turns: 3, result: text)

REVIEW = "## Findings\n\nOne **real** bug in `retry_count`.\n"
ANSWER = "# Repair items\n\n1. Do the thing.\n"
RUN_ONE = ["⚙️  extension command: review\n", "#{StreamRender::RUN_MARK}\n", tool("git diff origin/main"),
           result(REVIEW), "#{StreamRender::EXIT_MARK}0\n"].join
ASK = ["#{StreamRender::RUN_MARK}\n", "\n#{StreamRender::ASKED}\nlist the repair items\n\n",
       tool("bundle exec rspec spec/thing_spec.rb")].join
ASK_DONE = ASK + result(ANSWER) + "#{StreamRender::EXIT_MARK}0\n"

DB.setup!
DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
box = DB.row(<<~SQL)
  INSERT INTO bayboxes (login, host, ssh_user, port, private_key_enc, public_key)
  VALUES ('furkansahin', '203.0.113.10', 'ubi', 22, 'x', 'ssh-ed25519 AAAA') RETURNING id
SQL
def job(n, state: "done")
  DB.row(<<~SQL, [$box_id, n, "rq-ubicloud-ubicloud-#{n}", state])["id"]
    INSERT INTO review_jobs (login, baybox_id, repo, pr_number, box_name, state, created_at)
    VALUES ('furkansahin', $1, 'ubicloud/ubicloud', $2, $3, $4, now() + $2::int * interval '1 second') RETURNING id
  SQL
end
$box_id = box["id"]

puts "-- the review is kept when it first finishes --"
j1 = job(1, state: "running")
Jobs.finish(j1, "done", output: StreamRender.all(RUN_ONE))
check("kept", DB.row("SELECT first_answer FROM review_jobs WHERE id = $1", [j1])["first_answer"].strip, REVIEW.strip)
Jobs.finish(j1, "done", output: StreamRender.all(RUN_ONE + ASK_DONE))
check("and a follow-up's answer never takes its place",
      DB.row("SELECT first_answer FROM review_jobs WHERE id = $1", [j1])["first_answer"].strip, REVIEW.strip)
j2 = job(2)
DB.exec("UPDATE review_jobs SET output = $1 WHERE id = $2", [StreamRender.all(RUN_ONE), j2])
Jobs.reopen(j2, "furkansahin")
check("one finished before it was kept is kept when a follow-up reopens it",
      DB.row("SELECT first_answer FROM review_jobs WHERE id = $1", [j2])["first_answer"].to_s.strip, REVIEW.strip)
DB.exec("DELETE FROM review_jobs")

include Rack::Test::Methods
def app = ReviewQueue.app
GitHubOAuth.class_eval { define_method(:exchange) { |_| "gho_x" } }
GitHubClient.class_eval { define_method(:get) { |_| {"login" => "furkansahin"} } }
Runner.singleton_class.prepend(Module.new { def box_list(_) = [] })
get "/auth/start"; st = last_response.location[/state=([^&]+)/, 1]
get "/auth/callback?code=c&state=#{st}"

def card(body, id)
  from = body.index(%(id="job-#{id}")) or return ""
  rest = body[from..]
  stop = rest.index('<div class="card"', 10) || rest.length
  rest[0...stop]
end
RENDERED = "<h4>Findings</h4>"

puts "-- after a follow-up, read from the end of a long log --"
# The stored text is the rendered end of the log, and a review's own run is
# longer than that: its boundary is gone, and its end is the first thing there.
full = StreamRender.all(RUN_ONE + ASK_DONE)
cut = full[full.index("▸ ")..]
j = job(10)
DB.exec("UPDATE review_jobs SET output = $1, first_answer = $2, finished_at = now() WHERE id = $3", [cut, REVIEW, j])
get "/sessions"
c = card(last_response.body, j)
check("the review is rendered", c.include?(RENDERED), true)
check("not raw markdown", c.include?("## Findings"), false)
check("not called bay preparing the box", c.include?("preparing the box"), false)
check("the review is open", c.match?(/data-keep="sec-#{j}-review" open>\s*<summary >the review/), true)
check("and so is the newest answer", c.include?("<h3>Repair items</h3>") || c.include?("Repair items</h"), true)

puts "-- the review pushed out of the window altogether --"
past = "#{StreamRender::RUN}\n" + full[full.index(StreamRender::ASKED)..]
j = job(11)
DB.exec("UPDATE review_jobs SET output = $1, first_answer = $2, finished_at = now() WHERE id = $3", [past, REVIEW, j])
get "/sessions"
c = card(last_response.body, j)
check("is put back, rendered and open", [c.include?(RENDERED), c.include?(%(data-keep="sec-#{j}-review" open))], [true, true])
check("before the question it was asked about", c.index(RENDERED) < c.index("list the repair items"), true)

puts "-- while a follow-up runs --"
DB.exec("DELETE FROM review_jobs")
j = job(12, state: "running")
running = StreamRender.all(RUN_ONE + ASK)
DB.exec("UPDATE review_jobs SET output = $1, first_answer = $2, phase = 'reviewing' WHERE id = $3", [running, REVIEW, j])
get "/sessions"
page = last_response.body
c = card(page, j)
check("the review it asks about is there, rendered", c.include?(RENDERED), true)
pre = c[%r{<pre class="tail" id="t-#{j}"[^>]*>(.*?)</pre>}m, 1].to_s
check("the live panel holds this run", pre.include?("list the repair items") && pre.include?("rspec"), true)
check("and not the review again, raw", [pre.include?("Findings"), pre.include?("git diff")], [false, false])
base = c[/data-base="(\d+)"/, 1].to_i
shown = CGI.unescapeHTML(pre)
get "/sessions/tail?id=#{j}&offset=#{base + shown.bytesize}"
check("the offset it counts from is where the stored text has got to", JSON.parse(last_response.body).values_at("chunk", "reset"), ["", false])
check("and the stream is asked to start where the log is, not at a rendered count",
      page.include?('var rawOffset = "end";') && page.include?('"&offset=" + rawOffset'), true)

puts "-- the first review, still running: all of it, as before --"
DB.exec("DELETE FROM review_jobs")
j = job(13, state: "running")
DB.exec("UPDATE review_jobs SET output = $1, phase = 'reviewing' WHERE id = $2",
        [StreamRender.all("⚙️  extension command: review\n#{StreamRender::RUN_MARK}\n" + tool("git diff origin/main")), j])
get "/sessions"
c = card(last_response.body, j)
check("no review panel before there is a review", c.include?(%(data-keep="sec-#{j}-review")), false)
check("and the live panel from the start", [c.include?("extension command"), c[/data-base="(\d+)"/, 1]], [true, "0"])

puts "-- torn down, and loaded when opened --"
DB.exec("DELETE FROM review_jobs")
j = job(14)
DB.exec("UPDATE review_jobs SET output = $1, first_answer = $2, finished_at = now(), torn_down_at = now() WHERE id = $3",
        [full, REVIEW, j])
get "/sessions"
gone = last_response.body[last_response.body.index("Torn down (")..]
check("a torn-down review is rendered too", [gone.include?(RENDERED), gone.include?("## Findings")], [true, false])
get "/sessions/review?format=json&id=#{j}"
html = JSON.parse(last_response.body)["html"].to_s
check("one loaded when its panel opens comes rendered", [html.include?(RENDERED), html.include?(%(data-keep="sec-#{j}-review" open))], [true, true])
get "/sessions/review?format=json&id=999999"
check("and nothing for one that is not there", JSON.parse(last_response.body).values_at("found", "html"), [false, nil])

DB.exec("TRUNCATE review_jobs, bayboxes RESTART IDENTITY CASCADE")
puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
