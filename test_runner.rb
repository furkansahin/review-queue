#!/usr/bin/env ruby
# Runner tests:  bundle exec ruby test_runner.rb
# A fake bay on PATH, so these exercise the real code without a machine.
require "fileutils"
require "tmpdir"
ROOT = Dir.mktmpdir("rq-runner")
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
ENV["RQ_BAY_ROOT"] = ROOT
# Off by default in production, so the tests have to name one to exercise the
# pull. It is unresolvable on purpose: the fake ssh decides what happens.
ENV["RQ_BOX_BASE_IMAGE_SOURCE"] = "example.invalid/baybox:latest"
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
# bay needs the compose plugin, and docker only finds one under DOCKER_CONFIG.
FileUtils.mkdir_p(File.join(ROOT, "bin", "cli-plugins"))
File.write(File.join(ROOT, "bin", "cli-plugins", "docker-compose"), "#!/bin/sh\nexit 0\n")
File.chmod(0o755, File.join(ROOT, "bin", "cli-plugins", "docker-compose"))
%w[bay.toml db.compose.yml post-create.sh].each { |f| File.write(File.join(ROOT, "config", f), "# #{f}\n") }
FileUtils.mkdir_p(File.join(ROOT, "config", "bin"))
File.write(File.join(ROOT, "config", "bin", "helper"), "#!/bin/sh\n")
prompt = File.join(ROOT, "prompt.md")
File.write(prompt, "run the specs\n")
ENV["RQ_REVIEW_PROMPT"] = prompt
FAKE_HOME = File.join(ROOT, "fakehome")
FileUtils.mkdir_p(FAKE_HOME)
ENV["RQ_SSH_HOME"] = FAKE_HOME

require_relative "runner"
require_relative "crypto"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end
def calls = File.exist?("#{ROOT}/calls") ? File.read("#{ROOT}/calls") : ""

priv, _pub = BayBox.generate_keypair
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
# Real copies: bay rsyncs part of this folder into the box, and rsync refuses
# to replace a directory there with a symlink.
check("the shared config is copied in", File.exist?(File.join(dir, "db.compose.yml")), true)
check("as a real file, not a symlink", File.symlink?(File.join(dir, "db.compose.yml")), false)
check("with the same contents", File.read(File.join(dir, "db.compose.yml")),
      File.read(File.join(ROOT, "config", "db.compose.yml")))
check("directories are copied as directories, not links",
      File.directory?(File.join(dir, "bin")) && !File.symlink?(File.join(dir, "bin")), true)
check("bay.local.toml is this user's own", File.symlink?(File.join(dir, "bay.local.toml")), false)
toml = File.read(File.join(dir, "bay.local.toml"))
check("it names this user's alias", toml.include?('host = "rq-furkansahin"'), true)
# bay puts a synced file in the box's <repo>/.bay/ only when the config folder
# and the repo root differ. Equal, they went to the top of the checkout, and
# the setup step could not find post-create.sh.
check("the repo root is not the config folder", toml.include?("repoPath = "), true)
check("and it really is somewhere else",
      toml[/repoPath = "([^"]+)"/, 1] == Runner.config_dir("furkansahin"), false)
check("which exists, so bay can resolve it", Dir.exist?(Runner.repo_root("furkansahin")), true)
check("and carries the skills repo", toml.include?("furkansahin/skills"), true)

# The commands are the dashboard's now, not the repo's. Without them bay falls
# back to whatever the shared bay.toml defines -- which is how a review ran
# unpinned, on the default model, with none of the harness prompt.
check("it defines the review command", toml.include?("[commands]") && toml.include?("review ="), true)
check("and the follow-up command", toml.include?("ask ="), true)
check("the review is pinned to a model",
      toml.include?("--model opus") && toml.include?("--effort max"), true)
# Without this the box refuses rspec, psql and ruby, and every finding comes
# back read-only -- the harness cannot verify anything.
check("both may actually run things",
      toml.scan("--dangerously-skip-permissions").size, 2)
check("so is the follow-up",
      toml.scan("--model opus").size == 2 && toml.scan("--effort max").size == 2, true)
check("the review reads the harness prompt", toml.include?(".rq/review-prompt.md"), true)
check("the follow-up reads its question", toml.include?(".rq/followup.txt"), true)
check("and says what was asked", toml.include?("== you asked"), true)
# The review stamps its own start; the follow-up is stamped from here instead,
# because the box takes a second or two to get going and the worker looks in
# that gap. See the ask checks below.
check("the review stamps its own start", toml.scan(Runner::RUN_MARK).size, 1)
check("both after --, so a leading dash is text",
      toml.scan(/ -- \\"\$\(cat/).size, 2)
check("and by a relative path, never /workspace", toml.include?("/workspace"), false)
check("the key is written 0600",
      format("%o", File.stat(Runner.key_path("furkansahin")).mode & 0o777), "600")
check("the key is the decrypted one",
      File.read(Runner.key_path("furkansahin")).start_with?("-----BEGIN"), true)
sshcfg = File.read(Runner.ssh_config_path("furkansahin"))
check("ssh points at the user's machine", sshcfg.include?("HostName 10.0.0.5"), true)
# Every other doctor check passed without this, and the box build stopped at
# "missing required tools" with nothing naming compose.
compose_link = File.join(ROOT, "users", "furkansahin", "docker", "cli-plugins", "docker-compose")
check("compose is linked where docker looks", File.symlink?(compose_link), true)
check("and DOCKER_CONFIG points at that folder",
      Runner.send(:env_for, BOXROW)["DOCKER_CONFIG"],
      File.join(ROOT, "users", "furkansahin", "docker"))
# bay runs ssh itself, with no -F, so the config must resolve from HOME.
check("the alias is this user's alone", Runner.host_alias("furkansahin"), "rq-furkansahin")
check("two users cannot share an alias",
      Runner.host_alias("a") == Runner.host_alias("b"), false)
check("the config defines that alias", sshcfg.include?("Host rq-furkansahin"), true)
check("docker is pointed at it",
      Runner.send(:env_for, BOXROW)["DOCKER_HOST"], "ssh://rq-furkansahin")
# ssh reads ~/.ssh/config from the passwd entry, not $HOME, so the real home
# must include every user's config or the alias does not resolve at all.
home_cfg = File.join(FAKE_HOME, ".ssh", "config")
check("the real home includes the per-user configs",
      File.exist?(home_cfg) && File.read(home_cfg).include?("Include #{ROOT}/users/*/.ssh/config"), true)
check("the ssh directory is 0700",
      format("%o", File.stat(Runner.ssh_dir("furkansahin")).mode & 0o777), "700")

puts "-- the tokens reach bay, and nothing else does --"
File.delete("#{ROOT}/env.seen") if File.exist?("#{ROOT}/env.seen")
Runner.run(BOXROW, "ping")
seen = File.read("#{ROOT}/env.seen")
check("claude token is passed", seen.include?("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-TESTTOKEN"), true)
check("github token is passed", seen.include?("GITHUB_TOKEN=github_pat_TEST"), true)
check("docker is pointed at the machine", seen.include?("DOCKER_HOST=ssh://rq-furkansahin"), true)
check("BAY_HOME is this user's", seen.include?("BAY_HOME=#{ROOT}/users/furkansahin/bay"), true)

# The box reads $BAY_HOME/env, not bay's process environment. Without this file
# the box builds and then gh says "please run gh auth login".
envfile = File.join(Runner.bay_home("furkansahin"), "env")
body = File.read(envfile)
check("the env file bay injects exists", File.exist?(envfile), true)
check("it carries the claude token", body.include?("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-TESTTOKEN"), true)
check("and the github token, under both names",
      body.include?("GITHUB_TOKEN=github_pat_TEST") && body.include?("GH_TOKEN=github_pat_TEST"), true)
check("readable only by this user", format("%o", File.stat(envfile).mode & 0o777), "600")

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
check("a dead run no longer reports reviewing", Runner.run(BOXROW, "status rq-x-2")[:output] != "reviewing", true)

# ...but only the process that spawned it may judge that. web and worker are
# separate containers with separate pid namespaces, so the web container sees
# ESRCH for every healthy review. state_word, which the live log uses, must
# therefore report what the run wrote and nothing more -- it called a running
# review failed and ended the stream on it.
check("the state word itself ignores the pid",
      Runner.state_word("furkansahin", "rq-x-2"), "reviewing")
# A run this host lost is not a failed run. The box carries on -- a docker exec
# outlives its client -- so the worker must be told to take it back.
check("a vanished run reads as orphaned, not failed",
      Runner.run(BOXROW, "status rq-x-2")[:output], "orphaned")
File.write(File.join(sd, "state"), "done\n")
check("and still reports a finished run", Runner.state_word("furkansahin", "rq-x-2"), "done")
File.write(File.join(sd, "state"), "reviewing\n")
File.write(File.join(sd, "pid"), "#{Process.pid}\n")

puts "-- a review detaches and comes back --"
File.delete("#{ROOT}/calls") if File.exist?("#{ROOT}/calls")
res = Runner.run(BOXROW, "review ubicloud/ubicloud 6172 rq-ubicloud-6172")
check("it starts", res[:ok], true)
deadline = Time.now + 60
sleep 0.1 until File.read(File.join(Runner.state_dir("furkansahin", "rq-ubicloud-6172"), "state")).strip == "done" || Time.now > deadline
state_now = Runner.run(BOXROW, "status rq-ubicloud-6172")[:output]
puts "        (waited #{(Time.now - (deadline - 60)).round(1)}s)" if state_now != "done"
check("it reaches done", state_now, "done")
check("bay was asked to bring the box up on the pr", calls.include?("up rq-ubicloud-6172 --pr 6172"), true)
check("and then to run the review", calls.include?("run rq-ubicloud-6172 review"), true)

# The prompt has to reach the worktree, or the review runs with no
# instructions and claude answers "Input must be provided". This is checked by
# what landed, not by how the script reads: the first version invoked ssh
# through one variable holding "ssh -F <path>", which bash took as a single
# command name, and `|| true` hid the failure.
cmds = File.exist?("#{ROOT}/ssh.cmds") ? File.read("#{ROOT}/ssh.cmds") : ""
check("the prompt was placed on the machine",
      cmds.include?("ubicloud/.worktrees/rq-ubicloud-6172/.rq/review-prompt.md"), true)
check("with the prompt's own text",
      File.read("#{ROOT}/ssh.stdin").include?("run the specs"), true)

# And when it cannot be placed, the review must fail rather than run blind.
File.rename(File.join(ROOT, "bin", "ssh"), File.join(ROOT, "bin", "ssh.off"))
res = Runner.run(BOXROW, "review ubicloud/ubicloud 6173 rq-ubicloud-6173")
d6173 = Runner.state_dir("furkansahin", "rq-ubicloud-6173")
deadline = Time.now + 60
sleep 0.1 until File.read(File.join(d6173, "state")).strip != "building" || Time.now > deadline
check("a prompt that cannot be placed fails the review",
      Runner.run(BOXROW, "status rq-ubicloud-6173")[:output], "failed")
check("and says why", File.read(File.join(d6173, "build.log")).include?("could not place the review prompt"), true)
check("without ever running the review",
      calls.include?("run rq-ubicloud-6173 review"), false)
File.rename(File.join(ROOT, "bin", "ssh.off"), File.join(ROOT, "bin", "ssh"))
check("a bad repo never reaches bay",
      Runner.run(BOXROW, "review notarepo 1 rq-x-1")[:ok], false)

puts "-- a stale branch from a previous review is realigned --"
# gh pr checkout updates a branch named after the pull request's head. A second
# review of the same pull request, after a force push, is rejected as
# non-fast-forward and bay up dies. The repair runs before bay is called.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  args=("$@"); printf '%s' "${args[${#args[@]}-1]}" >> "#{ROOT}/align.sh"
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))
GitHubClient.class_eval { define_method(:try) { |_p| {"head" => {"ref" => "gcp-service-account-mode"}} } }

File.delete("#{ROOT}/align.sh") if File.exist?("#{ROOT}/align.sh")
Runner.align_pr_branch(BOXROW, "ubicloud/ubicloud", 5886)
sent = File.read("#{ROOT}/align.sh")
check("it works in the box's checkout", sent.include?("cd 'ubicloud'"), true)
check("only when the branch is actually there",
      sent.include?("git rev-parse --verify --quiet refs/heads/gcp-service-account-mode"), true)
check("and only when it has diverged",
      sent.include?("git merge-base --is-ancestor refs/heads/gcp-service-account-mode FETCH_HEAD && exit 0"), true)
check("never while somebody has it checked out", sent.include?("worktreepath"), true)
check("it moves the branch to the pull request head",
      sent.include?("git update-ref refs/heads/gcp-service-account-mode FETCH_HEAD"), true)
# A branch lives in one worktree at a time. A previous review leaves the base
# clone sitting on the pull request's branch, and then the review's own
# worktree cannot have it: "refusing to fetch into branch ... checked out at
# /workspace".
check("it frees the branch from the base clone",
      sent.include?("git symbolic-ref --quiet --short HEAD") && sent.include?("git checkout --quiet"), true)
check("onto whatever the base branch is, not a guess",
      sent.include?("refs/remotes/origin/HEAD"), true)
check("and gives up rather than forcing it",
      sent.include?("would not move"), true)

# A branch name reaches a shell on the box, so it is checked rather than trusted.
["a;id", "../../etc", "a b", "$(id)", "", "a..b"].each do |bad|
  GitHubClient.class_eval { define_method(:try) { |_p| {"head" => {"ref" => bad}} } }
  File.delete("#{ROOT}/align.sh") if File.exist?("#{ROOT}/align.sh")
  Runner.align_pr_branch(BOXROW, "ubicloud/ubicloud", 1)
  check("refuses branch name #{bad.inspect}", File.exist?("#{ROOT}/align.sh"), false)
end
GitHubClient.class_eval { define_method(:try) { |_p| nil } }
File.delete("#{ROOT}/align.sh") if File.exist?("#{ROOT}/align.sh")
Runner.align_pr_branch(BOXROW, "ubicloud/ubicloud", 1)
check("and does nothing when GitHub cannot be asked", File.exist?("#{ROOT}/align.sh"), false)

puts "-- preparing a box actually runs --"
# This is the one that got away. prepare_box builds a shell script, and the
# route tests stub it, so nothing ever called it -- a rewrite reintroduced a
# constant that had been renamed away and the whole page raised NameError for
# anyone setting up a machine. Call it for real against the fake ssh.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  args=("$@"); printf '%s' "${args[${#args[@]}-1]}" >> "#{ROOT}/prepare.sh"
  echo "  ready"
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))
File.delete("#{ROOT}/prepare.sh") if File.exist?("#{ROOT}/prepare.sh")

res = Runner.prepare_box(BOXROW)
check("it runs without raising", res[:ok], true)
sent = File.read("#{ROOT}/prepare.sh")
check("it installs docker", sent.include?("docker-ce"), true)
check("puts the user in the docker group", sent.include?("usermod -aG docker"), true)
check("clones the repository", sent.include?("git clone"), true)
check("into the path this box uses", sent.include?("'ubicloud'"), true)
check("takes a lock, so two presses do not fight", sent.include?("flock -n 9"), true)
check("and stops at the first failure", sent.include?("|| fail "), true)

# The prebaked image. Naming one the machine does not have makes bay look for
# it on Docker Hub and fail every build with "pull access denied" -- so a box
# only gets a baseImage line once it is known to have the image.
check("it reports the image it built", res[:base_image], Runner::BASE_IMAGE_TAG)
check("and the config names it",
      Runner.local_toml(BOXROW.merge("base_image" => Runner::BASE_IMAGE_TAG)).include?("baseImage = "), true)
check("a box without one gets no baseImage line",
      Runner.local_toml(BOXROW.merge("base_image" => nil)).include?("baseImage"), false)

# Three ways to get the image, and they differ by twenty-five minutes, so which
# one ran matters. This ssh records every docker command and obeys marker files
# for what the machine can do.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  args=("$@"); last="${args[${#args[@]}-1]}"
  echo "$last" >> "#{ROOT}/dockerlog"
  case "$last" in
    *"docker image inspect"*) [ -f "#{ROOT}/has-image" ] || exit 1 ;;
    *"docker pull"*)          [ -f "#{ROOT}/can-pull" ]  || exit 1 ;;
    *"docker build"*)         [ -f "#{ROOT}/can-build" ] || exit 1 ;;
  esac
  echo "  ready"; exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))

# Say which docker verbs one prepare used.
image_run = lambda do |*can|
  ["has-image", "can-pull", "can-build"].each { |m| FileUtils.rm_f(File.join(ROOT, m)) }
  can.each { |m| File.write(File.join(ROOT, m.to_s.tr("_", "-")), "") }
  File.write("#{ROOT}/dockerlog", "")
  out = Runner.prepare_box(BOXROW)
  log = File.read("#{ROOT}/dockerlog")
  verbs = {"inspect" => "docker image inspect", "pull" => "docker pull",
           "tag" => "docker tag", "build" => "docker build"}
  [out, verbs.select { |_, cmd| log.include?(cmd) }.keys]
end

already, verbs = image_run.call(:has_image)
check("a box that has the image is left alone", verbs, ["inspect"])
check("and keeps it", already[:base_image], Runner::BASE_IMAGE_TAG)

pulled, verbs = image_run.call(:can_pull, :can_build)
check("a box without it pulls instead of building", verbs, %w[inspect pull tag])
check("and records the image", pulled[:base_image], Runner::BASE_IMAGE_TAG)

built, verbs = image_run.call(:can_build)
check("a box that cannot pull builds", verbs, %w[inspect pull build])
check("and records the image too", built[:base_image], Runner::BASE_IMAGE_TAG)

# It must never be able to fail a setup: a box with no image is slower, not
# broken.
none, verbs = image_run.call
check("a box that can do neither still prepares", none[:ok], true)
check("and tried both first", verbs, %w[inspect pull build])
check("and says the boxes will be slow", none[:output].include?("build from scratch"), true)
check("and records no image", none[:base_image], nil)

# With no source named -- the default -- it must not reach for a registry at
# all, because that would be pulling someone else's image without being asked.
Runner.send(:remove_const, :BASE_IMAGE_SOURCE)
Runner.const_set(:BASE_IMAGE_SOURCE, "")
_, verbs = image_run.call(:can_build)
check("with no source named it never pulls", verbs, %w[inspect build])
Runner.send(:remove_const, :BASE_IMAGE_SOURCE)
Runner.const_set(:BASE_IMAGE_SOURCE, ENV["RQ_BOX_BASE_IMAGE_SOURCE"])

puts "-- the base image carries no host key --"
# openssh-server generates SSH host keys when it installs. Baking them into an
# image gives every box built from it, and everyone who pulls it, the same host
# identity with the private half included.
lines = File.read(Runner::BASE_IMAGE_DOCKERFILE)
           .gsub(/\\\n/, " ").lines.reject { |l| l.strip.start_with?("#") }
sshd = lines.find { |l| l.include?("openssh-server") }
check("openssh-server is installed", !sshd.nil?, true)
# In the same RUN. A later one only writes a whiteout -- the keys still travel
# inside the earlier layer and arrive with the pull.
check("and the same layer deletes the host keys",
      sshd.to_s.include?("rm -f /etc/ssh/ssh_host_*"), true)

puts "-- a lost run is taken back from the box --"
# The fake ssh answers `cat` with whatever is queued for it, so adopt sees the
# box's own copy of the output.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  cat "#{ROOT}/boxlog"
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))

File.write("#{ROOT}/boxlog", "#{Runner::RUN_MARK}\nhalf a review so far\n")
a = Runner.adopt(BOXROW, "rq-x-9")
check("an unfinished run is not called finished", a[:finished], false)
# The run boundary survives rendering: it is what the page splits panels on.
check("but its output is brought over", a[:output].include?("half a review so far"), true)
check("and this host says it is still going",
      Runner.state_word("furkansahin", "rq-x-9"), "reviewing")

File.write("#{ROOT}/boxlog", "#{Runner::RUN_MARK}\nthe whole review\n#{Runner::EXIT_MARK}0\n")
a = Runner.adopt(BOXROW, "rq-x-9")
check("a finished run is recognised", a[:finished], true)
check("with its exit code", a[:exit_code], 0)
check("the stamp is not part of the review", a[:output].include?(Runner::EXIT_MARK), false)
check("and this host agrees it is done",
      Runner.state_word("furkansahin", "rq-x-9"), "done")

File.write("#{ROOT}/boxlog", "#{Runner::RUN_MARK}\nit went wrong\n#{Runner::EXIT_MARK}1\n")
a = Runner.adopt(BOXROW, "rq-x-9")
check("a non-zero exit is a failure", Runner.state_word("furkansahin", "rq-x-9"), "failed")
check("and the output is still kept", a[:output].include?("it went wrong"), true)

# A follow-up appends to the same file, so the previous run's exit stamp is
# still in there when the new one starts. Reading that as "already finished"
# is what made a follow-up report the review it followed and stop.
File.write("#{ROOT}/boxlog",
  "#{Runner::RUN_MARK}\nyesterday's review\n#{Runner::EXIT_MARK}0\n" \
  "#{Runner::RUN_MARK}\n== you asked\nlist the repair items\n")
a = Runner.adopt(BOXROW, "rq-x-9")
check("a stale exit stamp does not finish the new run", a[:finished], false)
check("the question is in the output", a[:output].include?("list the repair items"), true)
check("and so is the review it follows", a[:output].include?("yesterday's review"), true)
check("the stamps themselves are not shown",
      a[:output].include?(Runner::RUN_MARK) || a[:output].include?(Runner::EXIT_MARK), false)

File.write("#{ROOT}/boxlog",
  "#{Runner::RUN_MARK}\nyesterday's review\n#{Runner::EXIT_MARK}0\n" \
  "#{Runner::RUN_MARK}\nthe answer\n#{Runner::EXIT_MARK}0\n")
a = Runner.adopt(BOXROW, "rq-x-9")
check("and once the new run ends, it is finished", a[:finished], true)
check("with both runs kept",
      a[:output].include?("yesterday's review") && a[:output].include?("the answer"), true)

# Restore the recording ssh for the checks below.
File.write(File.join(ROOT, "bin", "ssh"), <<~SH)
  #!/usr/bin/env bash
  args=("$@"); remote="${args[${#args[@]}-1]}"
  echo "$remote" >> "#{ROOT}/ssh.cmds"
  cat >> "#{ROOT}/ssh.stdin"
  exit 0
SH
File.chmod(0o755, File.join(ROOT, "bin", "ssh"))

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
# Stamped before the run is detached, or the worker reads the previous run's
# ending as this one's and answers a question with the last answer.
cmds = File.read("#{ROOT}/ssh.cmds")
check("the new run is opened before anything is started",
      cmds.include?("#{Runner::RUN_MARK}") && cmds.include?("run.log"), true)
check("and it appends rather than replacing the record",
      cmds.include?(">> "), true)
# The ask above is still running, and a box does one thing at a time.
check("a second question is refused while the first runs",
      Runner.run(BOXROW, "ask rq-ubicloud-6172", stdin: "again?")[:ok], false)

# A question is a question. Without a bound, a paste is a payload.
askdir = Runner.state_dir("furkansahin", "rq-ubicloud-6172")
deadline = Time.now + 60
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

# A review and a follow-up are detached on purpose, so some of them may still
# be writing into this tree. Removing it underneath them raised ENOENT from
# the cleanup itself -- every check passing and the run still exiting 1.
# Wait for them, then remove, and never let the tidying decide the result.
Dir.glob(File.join(ROOT, "users", "*", "state", "*", "pid")).each do |f|
  pid = File.read(f).to_i
  next unless pid.positive?
  deadline = Time.now + 30
  while Time.now < deadline
    begin
      Process.kill(0, pid)
    rescue StandardError
      break
    end
    sleep 0.1
  end
end
FileUtils.remove_entry(ROOT, true)
puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
