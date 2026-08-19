#!/usr/bin/env ruby
# Dev box tests:  bundle exec ruby test_devbox.rb
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "devbox"
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

priv, pub = DevBox.generate_keypair(comment: "review-queue")
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

line = DevBox.authorized_keys_line(pub)
check("forced command is set", line.start_with?('command="/usr/local/bin/rq-review",restrict '), true)
check("the key is in the line", line.include?(pub), true)

check("box name from repo and PR", DevBox.box_name("ubicloud/ubicloud", 6172), "rq-ubicloud-6172")

cmd = DevBox.review_command(repo: "ubicloud/ubicloud", pr_number: 6172, box: "rq-ubicloud-6172")
check("command is plain fields", cmd, "review ubicloud/ubicloud 6172 rq-ubicloud-6172")

# injection attempts must be refused before anything is sent
check("rejects shell metacharacters in repo",
      raises(DevBox::Error) { DevBox.review_command(repo: "o/r; rm -rf /", pr_number: 1, box: "b") }.start_with?("bad repo"), true)
check("rejects a non-numeric pull request",
      raises(DevBox::Error) { DevBox.review_command(repo: "o/r", pr_number: "1 && curl evil", box: "b") }.start_with?("bad pull request number"), true) if true
check("rejects a backtick in the box name",
      raises(DevBox::Error) { DevBox.review_command(repo: "o/r", pr_number: 1, box: "b`id`") }.start_with?("bad box name"), true)
check("rejects a newline in the box name",
      raises(DevBox::Error) { DevBox.review_command(repo: "o/r", pr_number: 1, box: "b\nreview x") }.start_with?("bad box name"), true)
check("rejects a path traversal repo",
      raises(DevBox::Error) { DevBox.review_command(repo: "../../etc", pr_number: 1, box: "b") }.start_with?("bad repo"), true)
check("rejects a bare repo name (the 'bad repo' bug)",
      raises(DevBox::Error) { DevBox.review_command(repo: "ubicloud", pr_number: 6172, box: "rq-x-1") }.start_with?("bad repo"), true)
check("accepts a normal repo", DevBox.review_command(repo: "o.r-1/re_po", pr_number: 9, box: "rq-x-9"),
      "review o.r-1/re_po 9 rq-x-9")

# an unreachable host returns data, it does not raise
row = {"host" => "127.0.0.1", "ssh_user" => "nobody", "port" => "1",
       "private_key_enc" => Crypto.encrypt(priv)}
res = DevBox.run(row, "ping", timeout: 3)
check("unreachable box returns ok=false", res[:ok], false)
check("unreachable box reports why", res[:error].to_s.empty?, false)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
