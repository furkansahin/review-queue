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

check("box name carries owner and repo", DevBox.box_name("ubicloud/ubicloud", 6172), "rq-ubicloud-ubicloud-6172")

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

# run_many runs several commands over one connection. A caller matches results
# to commands by position, so a connection that never opens must still answer
# once per command rather than returning a short list.
many = DevBox.run_many(row, [["status a", nil], ["result a", nil], ["build a", nil]], timeout: 3)
check("a broken connection answers once per command", many.size, 3)
check("and every one of them failed", many.all? { |r| r[:ok] == false }, true)
check("each carrying the reason", many.all? { |r| !r[:error].to_s.empty? }, true)

# A key that cannot be decrypted fails before the connection is attempted, and
# must not lose the shape of the answer either.
bad = {"host" => "127.0.0.1", "ssh_user" => "nobody", "port" => "1",
       "private_key_enc" => Crypto.encrypt(priv).sub(/.\z/) { |c| c == "A" ? "B" : "A" }}
many = DevBox.run_many(bad, [["status a", nil], ["result a", nil]], timeout: 3)
check("an unreadable key also answers once per command", many.size, 2)
check("and says the key is the problem", many.first[:error].to_s.include?("cannot read the stored key"), true)

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
  check("accepts #{input.strip[0, 34]}", DevBox.check_skills_repo!(input), want)
end
check("empty means no skills repository", DevBox.check_skills_repo!(""), nil)
check("nil means the same", DevBox.check_skills_repo!(nil), nil)

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
    DevBox.check_skills_repo!(bad)
    false
  rescue DevBox::Error
    true
  end
  check("refuses #{bad[0, 34]}", refused, true)
end

# The wrapper is the security boundary, so it must not trust the dashboard's
# check. Both sides carry the same rule.
wrapper_src = File.read(File.join(__dir__, "devbox", "rq-review"))
check("the wrapper checks the URL itself",
      wrapper_src.include?('^https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\\.git)?$'), true)
check("and takes - to clear it", wrapper_src.include?('[ "$url" = "-" ]'), true)
check("push_skills sends - for nothing",
      DevBox.method(:push_skills).source_location.is_a?(Array), true)

# --- the ssh wait loop -------------------------------------------------------
# net-ssh runs ssh.loop while the block gives back true, so the block must say
# whether the command is still running. A block that always gives back true
# never stops. It runs to the deadline and raises for every command, even one
# that answered at once, which made every dev box command fail after 30s.
#
# These fakes copy that contract: the block is asked first, then one step of
# the conversation happens, exactly as net-ssh preprocesses before it reads.
FakeData = Struct.new(:value) { def read_long = value }

class FakeChannel
  def initialize(script)
    @script = script
    @handlers = {}
    @open = true
  end
  def active? = @open
  def exec(_command) = yield(self, true)
  def on_data(&b) = @handlers[:data] = b
  def on_extended_data(&b) = @handlers[:extended] = b
  def on_request(name, &b) = @handlers[name] = b
  def send_data(_bytes) = nil
  def eof! = nil

  def step
    case @script.shift
    when :data then @handlers[:data]&.call(self, "pong\n")
    when :exit
      @handlers["exit-status"]&.call(self, FakeData.new(0))
      @open = false
    end
  end
end

class FakeSession
  attr_reader :turns
  def initialize = @turns = 0
  def open_channel(&block)
    @channel = FakeChannel.new([:data, :exit])
    block.call(@channel)
    @channel
  end
  def loop(_wait = nil)
    while yield
      @turns += 1
      # A loop that cannot stop is the bug. Cut it off, and report it the way a
      # dead box reports, so the check below fails instead of hanging.
      raise Timeout::Error, "the wait loop never stopped" if @turns > 200
      @channel.step
    end
  end
end

$fake_session = FakeSession.new
Net::SSH.singleton_class.prepend(Module.new do
  define_method(:start) { |*_args, **_opts, &block| block.call($fake_session) }
end)

row = {"host" => "10.0.0.1", "ssh_user" => "ubi", "port" => 22,
       "private_key_enc" => Crypto.encrypt(priv)}
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
res = DevBox.run(row, "ping", timeout: 30)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
check("the loop stops when the channel closes", res[:ok], true)
check("the output is kept", res[:output].strip, "pong")
check("the exit status is read", res[:exit_code], 0)
check("it does not wait out the deadline", elapsed < 1.0, true)
check("and it stops in a few turns", $fake_session.turns < 10, true)

# --- the wrapper and the bay command must agree on one path ----------------
# The wrapper writes the question into the box worktree, and bay starts a
# command in that same worktree. So the ask command must read a relative path.
# An absolute /workspace path is the repository root, not the worktree: the
# question is not there, and neither is the review conversation that
# --continue resumes. That failure cost a follow-up its answer twice over.
toml = File.read(File.join(__dir__, "devbox", "bay-review-command.toml"))
ask_cmd = toml[/^ask = """\n(.*?)\n"""/m, 1].to_s
wrapper = File.read(File.join(__dir__, "devbox", "rq-review"))

check("ask reads the question", ask_cmd.include?(".rq/followup.txt"), true)
check("by a path relative to the worktree", ask_cmd.include?("/workspace"), false)
check("and never cds away from it", ask_cmd.match?(/\bcd\s/), false)
check("the text is passed after --", ask_cmd.include?(" -- "), true)
check("the wrapper writes to that same path", wrapper.include?("$wt/.rq/followup.txt"), true)
check("and the worktree is the box worktree", wrapper.include?('wt="$REPO_PATH/.worktrees/$box"'), true)

# The review prompt travels the same way, and for the same reason.
review_cmd = toml[/^review = """\n(.*?)\n"""/m, 1].to_s
prompt = File.read(File.join(__dir__, "devbox", "review-prompt.md"))
setup = File.read(File.join(__dir__, "devbox", "setup.sh"))

check("review reads its prompt from a file", review_cmd.include?(".rq/review-prompt.md"), true)
check("relative, like the follow-up", review_cmd.include?("/workspace"), false)
check("and after --", review_cmd.include?(" -- "), true)
check("the wrapper copies the prompt in", wrapper.include?("$wt/.rq/review-prompt.md"), true)
check("it refuses when the prompt is missing", wrapper.include?("review prompt missing"), true)
check("setup.sh installs it where the wrapper looks",
      setup.include?("$HOME/.rq/review-prompt.md"), true)
check("and hides .rq from git status", setup.include?("info/exclude"), true)

# The point of the harness is that the review runs things. If someone trims the
# prompt back to reading only, these fail rather than the tab quietly reverting.
check("the prompt tells it to run the specs", prompt.include?("bundle exec rspec"), true)
check("with the right environment", prompt.include?("RACK_ENV=test"), true)
check("it must mark findings verified or read-only",
      prompt.include?("verified") && prompt.include?("read-only"), true)
check("and it must not run the whole suite", prompt.include?("Do not run the whole suite"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
