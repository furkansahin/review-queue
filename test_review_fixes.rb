#!/usr/bin/env ruby
# Regression tests for the review findings: bundle exec ruby test_review_fixes.rb
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "devbox"
require_relative "crypto"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-18s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,18], want.inspect)
end

# --- a nil exit status is a failure, not a success -------------------------
row = {"host" => "127.0.0.1", "ssh_user" => "nobody", "port" => "1",
       "private_key_enc" => Crypto.encrypt(DevBox.generate_keypair.first)}
res = DevBox.run(row, "ping", timeout: 2)
check("unreachable box is not ok", res[:ok], false)
check("and exit_code stays nil rather than 0", res[:exit_code], nil)

# the exact shape the review flagged: ok must come from code == 0
mod = DevBox.method(:run).source_location
src = File.read(mod[0])
check("run compares the exit code to 0, not to_i", src.include?("code == 0"), true)
code_lines = src.lines.reject { |l| l.strip.start_with?("#") }.join
check("the old to_i.zero? form is gone from code", code_lines.include?("code.to_i.zero?"), false)

# --- a wrong encryption key is reported, not raised ------------------------
ENV["RQ_ENCRYPTION_KEY"] = "f" * 64      # cannot decrypt what "0"*64 encrypted
res = DevBox.run(row, "ping", timeout: 2)
check("a wrong key is a handled failure", res[:ok], false)
check("and names the variable", res[:error].to_s.include?("RQ_ENCRYPTION_KEY"), true)
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
res = DevBox.run({"host" => "127.0.0.1", "ssh_user" => "x", "port" => "1",
                  "private_key_enc" => "not-encrypted-at-all"}, "ping", timeout: 2)
check("an unreadable stored key does not raise", res[:ok], false)

# --- box names must not collide across owners ------------------------------
a = DevBox.box_name("ubicloud/ubicloud", 5)
b = DevBox.box_name("furkansahin/ubicloud", 5)
check("different owners get different box names", a == b, false)
check("the owner is in the name", a, "rq-ubicloud-ubicloud-5")
check("an uppercase repo is usable", DevBox.box_name("ubicloud/Bay", 42), "rq-ubicloud-bay-42")
check("a dotted repo is usable", DevBox.box_name("o/r.rb", 7), "rq-o-r-rb-7")
long = DevBox.box_name("a" * 80 + "/" + "b" * 80, 6172)
check("a long repo still fits BOX_RE", long.match?(DevBox::BOX_RE), true)
check("and keeps the pull request number", long.end_with?("-6172"), true)
%w[ubicloud/ubicloud ubicloud/Bay o/r.rb].each do |r|
  n = DevBox.box_name(r, 1)
  check("box_name(#{r}) passes its own validator", n.match?(DevBox::BOX_RE), true)
end

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
