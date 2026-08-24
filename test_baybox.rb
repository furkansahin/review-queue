#!/usr/bin/env ruby
# Baybox tests:  bundle exec ruby test_baybox.rb
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "baybox"
require "tempfile"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-20s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,20], want.inspect[0,20])
end
def raises(klass)
  yield
  "no error"
rescue klass => e
  e.message
end

priv, pub = BayBox.generate_keypair(comment: "review-queue")
check("private key is a PEM", priv.start_with?("-----BEGIN"), true)
check("public key is ssh-rsa", pub.start_with?("ssh-rsa "), true)

# The real test: does OpenSSH itself accept the key we generated?
Tempfile.create(["k", ".pub"]) do |f|
  f.write(pub); f.flush
  out = `ssh-keygen -l -f #{f.path} 2>&1`.strip
  check("ssh-keygen parses our public key", $?.success?, true)
  puts "        #{out}"
end
# ...and does it match the private half?
Tempfile.create("id") do |f|
  f.write(priv); f.flush
  File.chmod(0o600, f.path)
  derived = `ssh-keygen -y -f #{f.path} 2>/dev/null`.strip
  check("public half matches the private half", derived.split[1], pub.split[1])
end

line = BayBox.authorized_keys_line(pub)
check("the key is restricted", line.start_with?("restrict "), true)
check("the key is in the line", line.include?(pub), true)

check("box name carries owner and repo", BayBox.box_name("ubicloud/ubicloud", 6172), "rq-ubicloud-ubicloud-6172")

bad = ->(**kw) { raises(BayBox::Error) { BayBox.validate!(**kw) } }
fields = {repo: "o.r-1/re_po", pr_number: 9, box: "rq-x-9"}
check("accepts a normal repo", BayBox.validate!(**fields), true)
check("rejects shell metacharacters in repo",
      bad.(**fields.merge(repo: "o/r; rm -rf /")).start_with?("bad repo"), true)
check("rejects a non-numeric pull request",
      bad.(**fields.merge(pr_number: "1 && curl evil")).start_with?("bad pull request number"), true)
check("rejects a backtick in the box name",
      bad.(**fields.merge(box: "b`id`")).start_with?("bad box name"), true)
check("rejects a newline in the box name",
      bad.(**fields.merge(box: "b\nreview x")).start_with?("bad box name"), true)
check("rejects a path traversal repo",
      bad.(**fields.merge(repo: "../../etc")).start_with?("bad repo"), true)
check("rejects a bare repo name (the 'bad repo' bug)",
      bad.(**fields.merge(repo: "ubicloud")).start_with?("bad repo"), true)

# --- box names must not collide across owners -------------------------------
# ubicloud/ubicloud and furkansahin/ubicloud shared rq-ubicloud-5, so each
# published the other's review and tearing one down removed the other's box.
check("different owners get different names",
      BayBox.box_name("ubicloud/ubicloud", 5) == BayBox.box_name("furkansahin/ubicloud", 5), false)
check("the owner is in the name", BayBox.box_name("ubicloud/ubicloud", 5), "rq-ubicloud-ubicloud-5")
check("an uppercase repo is usable", BayBox.box_name("ubicloud/Bay", 42), "rq-ubicloud-bay-42")
check("a dotted repo is usable", BayBox.box_name("o/r.rb", 7), "rq-o-r-rb-7")
long = BayBox.box_name("a" * 80 + "/" + "b" * 80, 6172)
check("a long repo still fits BOX_RE", long.match?(BayBox::BOX_RE), true)
check("and keeps the pull request number", long.end_with?("-6172"), true)

# --- the key line -----------------------------------------------------------
# bay needs git and docker over this connection, so the key cannot be pinned to
# one program. restrict is what survives that.
open_line = BayBox.authorized_keys_line("ssh-rsa AAAA")
check("the key is not pinned to a program", open_line.include?("command="), false)
check("but it keeps restrict", open_line.start_with?("restrict "), true)
check("and it is still the same key", open_line.end_with?("ssh-rsa AAAA"), true)

# --- the skills repository ---------------------------------------------------
# It is typed by a person, stored, written into a TOML file on the box, and
# handed to git clone inside a container. Only one shape survives that trip.
ok_skills = {
  "https://github.com/furkansahin/skills" => "https://github.com/furkansahin/skills",
  "https://github.com/a/b.git"            => "https://github.com/a/b.git",
  "furkansahin/skills"                    => "https://github.com/furkansahin/skills",
  "  furkansahin/skills  "                => "https://github.com/furkansahin/skills",
  "https://github.com/a/b/"               => "https://github.com/a/b"
}
ok_skills.each do |input, want|
  check("accepts #{input.strip[0, 34]}", BayBox.check_skills_repo!(input), want)
end
check("empty means no skills repository", BayBox.check_skills_repo!(""), nil)
check("nil means the same", BayBox.check_skills_repo!(nil), nil)

[
  "http://github.com/a/b",            # not https
  "https://gitlab.com/a/b",           # bay authenticates github only
  "https://github.com/a",             # no repository
  "https://x:y@github.com/a/b",       # carries its own credentials
  "https://github.com/a/b;id",        # shell metacharacter
  "https://github.com/a/b$(id)",
  "git@github.com:a/b.git",           # ssh form: no token auth in the box
  "https://github.com/a/b/../../c"    # traversal
].each do |bad|
  refused = begin
    BayBox.check_skills_repo!(bad)
    false
  rescue BayBox::Error
    true
  end
  check("refuses #{bad[0, 34]}", refused, true)
end

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
