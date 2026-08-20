#!/usr/bin/env ruby
# Runner tests:  bundle exec ruby test_runner.rb
# A fake bay on PATH, so these exercise the real code without a machine.
require "fileutils"
require "tmpdir"
ROOT = Dir.mktmpdir("rq-runner")
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
ENV["RQ_BAY_ROOT"] = ROOT
FileUtils.mkdir_p([File.join(ROOT, "bin"), File.join(ROOT, "config")])
# A bay that records what it was asked and answers plausibly.
File.write(File.join(ROOT, "bin", "bay"), <<~SH)
  #!/usr/bin/env bash
  echo "$@" >> "#{ROOT}/calls"
  env | grep -E '^(BAY_HOME|BAY_CONFIG|DOCKER_HOST|CLAUDE_CODE_OAUTH_TOKEN|GITHUB_TOKEN)=' >> "#{ROOT}/env.seen"
  case "$1" in
    list) echo "/home/ubi/ubicloud                            abc123 [main]"
          echo "/home/ubi/ubicloud/.worktrees/rq-x-1          def456 [jesse/rq-x-1]" ;;
    down) echo "torn down $2" ;;
    up)   echo "box up $2" ;;
    run)  echo "ran $3 in $2" ;;
  esac
  [ -n "$RQ_FAKE_FAIL" ] && exit 1
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "bay"))
# A fake ssh, because ask and the review prompt put files on the machine over
# the same connection bay uses. It records the remote command and the bytes.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  args=("$@"); remote="${args[${#args[@]}-1]}"
  echo "$remote" >> "#{ROOT}/ssh.cmds"
  cat >> "#{ROOT}/ssh.stdin"
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))
%w[bay.toml db.compose.yml post-create.sh].each { |f| File.write(File.join(ROOT, "config", f), "# #{f}\n") }
prompt = File.join(ROOT, "prompt.md")
File.write(prompt, "run the specs\n")
ENV["RQ_REVIEW_PROMPT"] = prompt

require_relative "runner"
require_relative "crypto"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end
def calls = File.exist?("#{ROOT}/calls") ? File.read("#{ROOT}/calls") : ""

priv, _pub = DevBox.generate_keypair
BOXROW = {"id" => 1, "login" => "furkansahin", "host" => "10.0.0.5", "ssh_user" => "ubi",
          "port" => 22, "private_key_enc" => Crypto.encrypt(priv),
          "skills_repo" => "https://github.com/furkansahin/skills",
          "repo_path" => "ubicloud",
          "claude_token_enc" => Crypto.encrypt("sk-ant-oat01-TESTTOKEN"),
          "github_token_enc" => Crypto.encrypt("github_pat_TEST")}

puts "-- it is switched on when bay is there --"
check("enabled", Runner.enabled?, true)
check("no reason to complain", Runner.unavailable_reason, nil)

puts "-- per-user isolation --"
check("each user has their own bay home",
      Runner.bay_home("a") != Runner.bay_home("b"), true)
check("a login cannot escape the root",
      begin; Runner.user_dir("../../etc"); false; rescue Runner::Error; true; end, true)
check("nor with a slash",
      begin; Runner.user_dir("a/b"); false; rescue Runner::Error; true; end, true)

puts "-- prepare! writes what bay needs --"
Runner.prepare!(BOXROW)
dir = Runner.config_dir("furkansahin")
check("the shared config is linked in", File.symlink?(File.join(dir, "db.compose.yml")), true)
check("bay.local.toml is this user's own", File.symlink?(File.join(dir, "bay.local.toml")), false)
toml = File.read(File.join(dir, "bay.local.toml"))
check("it names the remote", toml.include?('host = "rqremote"'), true)
check("and carries the skills repo", toml.include?("furkansahin/skills"), true)
check("the key is written 0600",
      format("%o", File.stat(Runner.key_path("furkansahin")).mode & 0o777), "600")
check("the key is the decrypted one",
      File.read(Runner.key_path("furkansahin")).start_with?("-----BEGIN"), true)
sshcfg = File.read(Runner.ssh_config_path("furkansahin"))
check("ssh points at the user's machine", sshcfg.include?("HostName 10.0.0.5"), true)
# bay runs ssh itself, with no -F, so the config must resolve from HOME.
check("the config is where ssh looks by itself",
      Runner.ssh_config_path("furkansahin"), File.join(ROOT, "users", "furkansahin", ".ssh", "config"))
check("and HOME points at that user", Runner.send(:env_for, BOXROW)["HOME"],
      File.join(ROOT, "users", "furkansahin"))
check("the ssh directory is 0700",
      format("%o", File.stat(Runner.ssh_dir("furkansahin")).mode & 0o777), "700")

puts "-- the tokens reach bay, and nothing else does --"
File.delete("#{ROOT}/env.seen") if File.exist?("#{ROOT}/env.seen")
Runner.run(BOXROW, "ping")
seen = File.read("#{ROOT}/env.seen")
check("claude token is passed", seen.include?("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-TESTTOKEN"), true)
check("github token is passed", seen.include?("GITHUB_TOKEN=github_pat_TEST"), true)
check("docker is pointed at the machine", seen.include?("DOCKER_HOST=ssh://rqremote"), true)
check("BAY_HOME is this user's", seen.include?("BAY_HOME=#{ROOT}/users/furkansahin/bay"), true)

puts "-- the verbs --"
check("ping proves the chain", Runner.run(BOXROW, "ping")[:ok], true)
boxes = Runner.box_list(BOXROW)
check("list names only worktrees", boxes.map(&:first), ["rq-x-1"])
check("teardown asks bay to go down",
      Runner.run(BOXROW, "teardown rq-x-1")[:ok] && calls.include?("down rq-x-1 --force"), true)
check("a bad box name is refused", Runner.run(BOXROW, "teardown ../etc")[:ok], false)
check("an unknown verb is refused", Runner.run(BOXROW, "wat")[:ok], false)

puts "-- status and logs come from this host now --"
sd = Runner.state_dir("furkansahin", "rq-x-2")
FileUtils.mkdir_p(sd)
File.write(File.join(sd, "state"), "reviewing\n")
File.write(File.join(sd, "pid"), "#{Process.pid}\n")
File.write(File.join(sd, "log"), "claude said things\n")
check("status reads the state", Runner.run(BOXROW, "status rq-x-2")[:output], "reviewing")
check("result reads the log", Runner.run(BOXROW, "result rq-x-2")[:output], "claude said things\n")
check("an unknown box is unknown", Runner.run(BOXROW, "status rq-nope")[:output], "unknown")

# A detached run that died must not still claim to be working: the worker would
# poll it until the staleness timeout instead of failing it now.
File.write(File.join(sd, "pid"), "999999\n")
check("a dead run reports failed, not reviewing", Runner.run(BOXROW, "status rq-x-2")[:output], "failed")

puts "-- a review detaches and comes back --"
File.delete("#{ROOT}/calls") if File.exist?("#{ROOT}/calls")
res = Runner.run(BOXROW, "review ubicloud/ubicloud 6172 rq-ubicloud-6172")
check("it starts", res[:ok], true)
deadline = Time.now + 15
sleep 0.1 until File.read(File.join(Runner.state_dir("furkansahin", "rq-ubicloud-6172"), "state")).strip == "done" || Time.now > deadline
check("it reaches done", Runner.run(BOXROW, "status rq-ubicloud-6172")[:output], "done")
check("bay was asked to bring the box up on the pr", calls.include?("up rq-ubicloud-6172 --pr 6172"), true)
check("and then to run the review", calls.include?("run rq-ubicloud-6172 review"), true)
check("a bad repo never reaches bay",
      Runner.run(BOXROW, "review notarepo 1 rq-x-1")[:ok], false)

puts "-- a follow-up needs a finished review --"
STDIN_TEXT = "why is finding 1 exploitable?"
File.delete("#{ROOT}/ssh.stdin") if File.exist?("#{ROOT}/ssh.stdin")
File.delete("#{ROOT}/ssh.cmds") if File.exist?("#{ROOT}/ssh.cmds")
res = Runner.run(BOXROW, "ask rq-ubicloud-6172", stdin: STDIN_TEXT)
check("it is accepted once the review is done", res[:ok], true)
check("the question is written into the box worktree",
      File.read("#{ROOT}/ssh.stdin"), STDIN_TEXT)
check("at the path the bay command reads",
      File.read("#{ROOT}/ssh.cmds").include?("ubicloud/.worktrees/rq-ubicloud-6172/.rq/followup.txt"), true)
# The ask above is still running, and a box does one thing at a time.
check("a second question is refused while the first runs",
      Runner.run(BOXROW, "ask rq-ubicloud-6172", stdin: "again?")[:ok], false)

# A question is a question. Without a bound, a paste is a payload.
askdir = Runner.state_dir("furkansahin", "rq-ubicloud-6172")
deadline = Time.now + 15
sleep 0.1 until File.read(File.join(askdir, "state")).strip == "done" || Time.now > deadline
File.delete("#{ROOT}/ssh.stdin")
Runner.run(BOXROW, "ask rq-ubicloud-6172", stdin: "x" * 20_000)
check("and it is bounded", File.size("#{ROOT}/ssh.stdin"), 8192)
check("an empty question is refused", Runner.run(BOXROW, "ask rq-ubicloud-6172", stdin: "  ")[:ok], false)
check("a box with no review is refused", Runner.run(BOXROW, "ask rq-never")[:ok], false)

puts "-- without bay, it says so instead of failing oddly --"
File.chmod(0o644, File.join(ROOT, "bin", "bay"))
check("disabled", Runner.enabled?, false)
check("and names the reason", Runner.unavailable_reason.include?("bay is not installed"), true)
check("a command fails with that reason", Runner.run(BOXROW, "ping")[:error].to_s.include?("bay is not installed"), true)
File.chmod(0o755, File.join(ROOT, "bin", "bay"))

FileUtils.remove_entry(ROOT)
puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
