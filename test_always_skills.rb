#!/usr/bin/env ruby
# Skills every run applies, fetched fresh:  bundle exec ruby test_always_skills.rb
require "tmpdir"
require_relative "always_skills"
require "net/http"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

$answers = []
$asked = 0
AlwaysSkills.singleton_class.prepend(Module.new do
  def fetch(name)
    $asked += 1
    a = $answers.shift
    raise a if a.is_a?(String) && a.start_with?("ERR")
    a
  end
end)
root = Dir.mktmpdir("always")
logged = []
log = ->(m) { logged << m }
path = File.join(root, "always-skills", "jeremy-lens", "SKILL.md")

puts "-- the list --"
check("jeremy-lens, by default", AlwaysSkills::NAMES, ["jeremy-lens"])
check("from your skills repository", AlwaysSkills.repo_path, "furkansahin/skills")

puts "-- a copy for each run --"
$answers = ["# jeremy-lens\\nv1\\n"]
check("fetched the first time", AlwaysSkills.files(root, log: log), [["jeremy-lens", path]])
check("and kept", File.read(path), "# jeremy-lens\\nv1\\n")
$asked = 0
AlwaysSkills.files(root, log: log)
check("a fresh copy is used as it is", $asked, 0)
File.utime(Time.now - 3600, Time.now - 3600, path)
$answers = ["# jeremy-lens\\nv2\\n"]
AlwaysSkills.files(root, log: log)
check("an old one is fetched again", File.read(path), "# jeremy-lens\\nv2\\n")
File.utime(Time.now - 3600, Time.now - 3600, path)
$answers = ["ERR GitHub answered 503"]
check("GitHub down: the last good copy", AlwaysSkills.files(root, log: log), [["jeremy-lens", path]])
check("still v2", File.read(path), "# jeremy-lens\\nv2\\n")
check("and it says so", logged.last.to_s.include?("using the copy from"), true)
empty = Dir.mktmpdir("always")
$answers = ["ERR GitHub answered 404"]
check("never fetched and GitHub down: left out", AlwaysSkills.files(empty, log: log), [])

puts "-- what is not a skill --"
names = `RQ_ALWAYS_SKILLS="jeremy-lens, ../etc, Bad Name,furkan-review-voice" ruby -e 'require "./always_skills"; print AlwaysSkills::NAMES.join(",")'`
check("only names a folder can have", names, "jeremy-lens,furkan-review-voice")
# The download itself, against answers made here.
def answer_with(code, body)
  res = Net::HTTPResponse::CODE_TO_OBJ[code].new("1.1", code, "x")
  res.instance_variable_set(:@body, body)
  res.instance_variable_set(:@read, true)
  fake = Object.new
  fake.define_singleton_method(:request) { |req| $url = req.uri.to_s; res }
  Net::HTTP.define_singleton_method(:start) { |*_, **_, &blk| blk.call(fake) }
end
real = AlwaysSkills.method(:fetch).super_method   # past the stand-in above
answer_with("200", "# jeremy-lens\nrules\n")
check("read from the repository's default branch", [real.call("jeremy-lens"), $url],
      ["# jeremy-lens\nrules\n", "https://raw.githubusercontent.com/furkansahin/skills/HEAD/jeremy-lens/SKILL.md"])
answer_with("404", "Not Found")
check("a skill that is not there is an error", (real.call("nope") rescue $!.message), "GitHub answered 404 for nope/SKILL.md")
answer_with("200", "  \n")
check("so is an empty one", (real.call("jeremy-lens") rescue $!.message), "jeremy-lens/SKILL.md is empty")
answer_with("200", "x" * 200_001)
check("and one too big to be a skill", (real.call("jeremy-lens") rescue $!.message), "jeremy-lens/SKILL.md is over 200000 bytes")

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
