require "open3"
require "fileutils"
require "json"
require_relative "crypto"
require_relative "devbox"

# Drives bay from this host instead of from the user's box.
#
# bay already knows how to work a remote Docker host: DOCKER_HOST=ssh://<host>
# for containers, ssh for git and worktrees. So the dashboard runs bay, points
# it at the user's own machine, and the containers still live there. What used
# to be a shell wrapper installed on every box (rq-review, its own verbs, its
# own state files) is this file instead -- one copy, deployed with the app.
#
# Each user gets their own bay home, their own config, their own state. Nothing
# is shared between two users except the read-only tooling in bin/ and the
# repo's config folder, which is the same for everybody.
#
# The verbs are the same words the wrapper used, so jobs.rb, worker.rb and the
# routes did not have to learn a new vocabulary.
module Runner
  extend self

  class Error < StandardError; end

  # Everything that must outlive a deploy: the binaries, the shared config, and
  # each user's state. A Dokku slug is replaced on every push, so this is a
  # persistent mount, not part of the app.
  ROOT = ENV.fetch("RQ_BAY_ROOT", "/app/rqbay")
  BIN = File.join(ROOT, "bin")
  BAY = File.join(BIN, "bay")
  # docker looks for its plugins under $DOCKER_CONFIG/cli-plugins, not on PATH,
  # so staging the binary is not enough on its own.
  COMPOSE = File.join(BIN, "cli-plugins", "docker-compose")
  # The repo's own bay config folder (bay-ubicloud): compose files, post-create,
  # seed-account, nvim. Shared by every user, read only.
  SHARED_CONFIG = File.join(ROOT, "config")
  # The review instructions, deployed with the app rather than installed on each
  # box. Overridable for tests.
  PROMPT = ENV.fetch("RQ_REVIEW_PROMPT", File.join(__dir__, "devbox", "review-prompt.md"))

  BOX_RE = /\A[a-z0-9][a-z0-9-]{0,48}\z/

  def enabled? = File.executable?(BAY) && File.directory?(SHARED_CONFIG) && File.exist?(COMPOSE)

  # Why not, in a sentence, for the Dev box page to show.
  def unavailable_reason
    return nil if enabled?
    return "bay is not installed at #{BAY}" unless File.executable?(BAY)
    return "the docker compose plugin is missing at #{COMPOSE}" unless File.exist?(COMPOSE)
    "the bay config folder is missing at #{SHARED_CONFIG}"
  end

  # --- per-user layout -------------------------------------------------------
  # A login is already restricted to a GitHub username by the allowlist, but it
  # names a directory here, so it is checked again rather than trusted.
  def user_dir(login)
    name = login.to_s
    raise Error, "bad login" unless name.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/)
    File.join(ROOT, "users", name)
  end

  def bay_home(login) = File.join(user_dir(login), "bay")
  def config_dir(login) = File.join(bay_home(login), "ubicloud")
  def state_dir(login, box) = File.join(user_dir(login), "state", box)
  def ssh_dir(login) = File.join(user_dir(login), ".ssh")

  # One alias per user, not one name shared by everybody: several users' configs
  # are visible to the same ssh, so the alias has to say whose machine it is.
  def host_alias(login) = "rq-#{login}"
  def key_path(login) = File.join(ssh_dir(login), "key")

  # Builds (or refreshes) everything bay needs for this user. Cheap enough to
  # run before every command, which means a box that was registered while the
  # mount was empty still works on the next try.
  def prepare!(box_row)
    login = box_row["login"]
    raise Error, unavailable_reason unless enabled?

    dir = config_dir(login)
    FileUtils.mkdir_p([dir, ssh_dir(login), File.join(user_dir(login), "state")])
    File.chmod(0o700, ssh_dir(login))

    # Real copies, not symlinks. bay rsyncs part of this folder into the box
    # (box.sync), and rsync will not replace a directory on the far side with a
    # symlink -- it stops with "could not make way for new symlink: bin" and the
    # box never builds. Copying costs a few dozen small files per user.
    #
    # Only bay.local.toml is this user's own, so it is never overwritten here.
    Dir.children(SHARED_CONFIG).each do |entry|
      next if entry == "bay.local.toml" || entry == "cache"
      src = File.join(SHARED_CONFIG, entry)
      dst = File.join(dir, entry)
      # A symlink means this user was prepared by an older version. Replace it.
      stale = File.symlink?(dst) || !File.exist?(dst) || File.mtime(src) > File.mtime(dst)
      next unless stale
      FileUtils.rm_rf(dst)
      FileUtils.cp_r(src, dst, remove_destination: true)
    end

    write_private(key_path(login), Crypto.decrypt(box_row["private_key_enc"]))
    write_file(ssh_config_path(login), ssh_config(box_row), 0o600)
    link_ssh_config!
    write_file(File.join(dir, "bay.local.toml"), local_toml(box_row), 0o600)
    write_env_file!(box_row)
    link_compose!(login)
    dir
  end

  # bay injects $BAY_HOME/env into the box -- that is where a developer's own
  # tokens live in ~/.bay/env, and it is the only place bay looks. Passing them
  # in this process's environment does nothing: a box built that way came up
  # with gh saying "please run gh auth login".
  #
  # So the tokens are written out, for this user alone, 0600, inside the mount.
  # That is the trade this migration made explicit: they are on this host now.
  def write_env_file!(box_row)
    lines = ["# Written by review-queue from the dashboard's stored tokens."]
    {"CLAUDE_CODE_OAUTH_TOKEN" => "claude_token_enc",
     "GITHUB_TOKEN" => "github_token_enc",
     # gh reads GH_TOKEN first and GITHUB_TOKEN second, but only the latter is
     # what bay's own docs name, so write both from the one stored value.
     "GH_TOKEN" => "github_token_enc"}.each do |key, column|
      value = decrypt_or_nil(box_row[column])
      lines << "#{key}=#{value}" if value && !value.empty?
    end
    write_file(File.join(bay_home(box_row["login"]), "env"), lines.join("\n") + "\n", 0o600)
  end

  def decrypt_or_nil(stored)
    return nil if stored.to_s.empty?
    Crypto.decrypt(stored)
  rescue Crypto::Error
    nil
  end

  # bay drives docker compose, and docker finds a plugin only under
  # $DOCKER_CONFIG/cli-plugins. Without this the box build stops at
  # "missing required tools" with every other check passing.
  def link_compose!(login)
    link = File.join(user_dir(login), "docker", "cli-plugins", "docker-compose")
    return if File.symlink?(link) && File.readlink(link) == COMPOSE
    FileUtils.mkdir_p(File.dirname(link))
    FileUtils.rm_f(link)
    FileUtils.ln_s(COMPOSE, link)
  end

  def ssh_config_path(login) = File.join(ssh_dir(login), "config")

  # ssh reads ~/.ssh/config from the passwd entry, not from $HOME -- setting
  # HOME does not move it, which is why the alias did not resolve at first. So
  # the real home gets one Include line covering every user's own config. The
  # home is the slug, replaced on each deploy, so this is written every time.
  # RQ_SSH_HOME exists so a test never writes into a real person's ~/.ssh. It
  # is not a production setting: in the container this is the passwd home.
  def ssh_home = ENV.fetch("RQ_SSH_HOME", Dir.home)

  def link_ssh_config!
    home = ssh_home
    dir = File.join(home, ".ssh")
    FileUtils.mkdir_p(dir)
    File.chmod(0o700, dir)
    path = File.join(dir, "config")
    line = "Include #{File.join(ROOT, "users", "*", ".ssh", "config")}"
    body = File.exist?(path) ? File.read(path) : ""
    return if body.include?(line)
    # Include has to come first: an Include inside a Host block only applies
    # to that block.
    File.write(path, "#{line}\n#{body}")
    File.chmod(0o600, path)
  rescue SystemCallError
    # A read-only home is not fatal on its own; the command below will say so.
    nil
  end

  # The one file that differs per user: which machine is theirs, and which
  # skills repository their boxes get.
  # The two commands the dashboard drives. They live here, generated, rather
  # than in the repo's shared bay.toml, which is the point of running one bay:
  # they are versioned with this app and every user gets the same pair. bay
  # merges the commands map across config layers, so the repo's own commands
  # (pry, agent, seed-account, the dataplane pair) are still there.
  #
  # Both are pinned. Unpinned, a review runs on whatever the box's account
  # happens to default to, which moves between releases -- so the same pull
  # request could be reviewed at two depths, unattended, with nobody to notice
  # a shallow answer.
  #
  # Both read their text from a file in the worktree rather than a command
  # line: free text never gets parsed by a shell, and the path is relative
  # because bay starts a command in the box's own worktree.
  REVIEW_CMD = 'claude -p --model opus --effort max -- "$(cat .rq/review-prompt.md)" 2>&1'
  ASK_CMD = 'claude -p --continue --model opus --effort max -- "$(cat .rq/followup.txt)" 2>&1'

  def local_toml(box_row)
    lines = ["# Written by review-queue. Edits here are overwritten.",
             "", "[remote]", %(host = #{host_alias(box_row["login"]).inspect}),
             %(repo = #{(box_row["repo_path"] || "ubicloud").inspect}), "", "[box]"]
    skills = box_row["skills_repo"].to_s.strip
    lines << %(claudeSkills = #{skills.inspect}) unless skills.empty?
    base = ENV["RQ_BOX_BASE_IMAGE"].to_s.strip
    lines << %(baseImage = #{base.inspect}) unless base.empty?
    lines += ["", "[commands]",
              "review = #{REVIEW_CMD.inspect}",
              "ask = #{ASK_CMD.inspect}"]
    lines.join("\n") + "\n"
  end

  def ssh_config(box_row)
    <<~SSH
      # Written by review-queue. Edits here are overwritten.
      Host #{host_alias(box_row["login"])}
        HostName #{box_row["host"]}
        User #{box_row["ssh_user"]}
        Port #{box_row["port"]}
        IdentityFile #{key_path(box_row["login"])}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        UserKnownHostsFile #{File.join(ssh_dir(box_row["login"]), "known_hosts")}
        BatchMode yes
        ConnectTimeout 15
    SSH
  end

  # --- running bay -----------------------------------------------------------
  # The tokens are the user's, decrypted for the length of one command and
  # passed in the environment, because that is where bay reads them: it hands
  # its own environment to the box it builds.
  def env_for(box_row)
    login = box_row["login"]
    ssh = "ssh -F #{ssh_config_path(login)}"
    env = {
      "PATH" => "#{BIN}:#{ENV["PATH"]}",
      "HOME" => user_dir(login),
      "BAY_HOME" => bay_home(login),
      "BAY_CONFIG" => File.join(config_dir(login), "bay.toml"),
      "DOCKER_HOST" => "ssh://#{host_alias(login)}",
      "DOCKER_CONFIG" => File.join(user_dir(login), "docker"),
      # bay runs `ssh` itself for DOCKER_HOST and for git, with no -F of its
      # own, so the host alias has to resolve from $HOME/.ssh/config. Setting
      # GIT_SSH_COMMAND as well costs nothing and is explicit for git.
      "GIT_SSH_COMMAND" => ssh
    }
    # Also in this process's environment, for bay's own git over https. The box
    # gets them from $BAY_HOME/env instead -- see write_env_file!.
    env["CLAUDE_CODE_OAUTH_TOKEN"] = decrypt_or_nil(box_row["claude_token_enc"])
    env["GITHUB_TOKEN"] = decrypt_or_nil(box_row["github_token_enc"])
    env.compact
  end

  # Runs bay once and waits. Never raises for a non-zero exit: a failure is
  # data, the same shape the ssh transport returned, so callers did not change.
  def bay(box_row, *args, timeout: 120, stdin: nil)
    prepare!(box_row)
    capture([BAY, *args], env_for(box_row), timeout: timeout, stdin: stdin)
  rescue Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message}
  end

  def capture(argv, env, timeout:, stdin: nil)
    out = +""
    status = nil
    Open3.popen2e(env, *argv, unsetenv_others: true) do |i, o, t|
      i.write(stdin) if stdin
      i.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      reader = Thread.new { o.each_line { |l| out << l } }
      unless t.join(timeout)
        Process.kill("TERM", t.pid) rescue nil
        sleep 0.5
        Process.kill("KILL", t.pid) rescue nil
        reader.kill
        return {ok: false, output: out, exit_code: nil,
                error: "timed out after #{timeout}s", timed_out: true}
      end
      reader.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 5].min.clamp(0, 5))
      reader.kill
      status = t.value
    end
    {ok: status&.success? || false, output: out, exit_code: status&.exitstatus}
  rescue Errno::ENOENT => e
    {ok: false, output: "", exit_code: nil, error: "cannot run bay: #{e.message}"}
  end

  # --- the verbs -------------------------------------------------------------
  # Same words the wrapper used, so the worker and the routes are unchanged.
  def run(box_row, command, timeout: 120, stdin: nil)
    verb, *rest = command.to_s.split(" ")
    case verb
    when "ping"     then ping(box_row)
    when "list"     then list(box_row)
    when "status"   then read_state(box_row, rest[0])
    when "result"   then read_log(box_row, rest[0], "log", 200_000)
    when "build"    then read_log(box_row, rest[0], "build.log", 40_000)
    when "teardown" then teardown(box_row, rest[0])
    when "review"   then review(box_row, repo: rest[0], pr_number: rest[1], box: rest[2])
    when "ask"      then ask(box_row, rest[0], stdin)
    when "skills"   then skills(box_row, rest[0])
    else {ok: false, output: "", exit_code: nil, error: "unknown command #{verb.inspect}"}
    end
  end

  # One connection per command is gone: bay is local now, so several commands
  # are just several calls. The name stays because the worker asks for two.
  def run_many(box_row, commands, timeout: 120)
    commands.map do |entry|
      command, stdin = entry.is_a?(Array) ? entry : [entry, nil]
      run(box_row, command, timeout: timeout, stdin: stdin)
    end
  end

  def check(box_row) = ping(box_row)

  # The sessions page asks for this by name. Cached the same way the ssh
  # transport cached it, because bay list is a round trip to the machine.
  LIST_TTL = Integer(ENV.fetch("RQ_BOX_LIST_TTL", "15"))
  @list_cache = {}
  @list_lock = Mutex.new

  def box_list(box_row)
    key = box_row["id"]
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    hit = @list_lock.synchronize { @list_cache[key] }
    return hit[:boxes] if hit && (now - hit[:at]) < LIST_TTL

    res = list(box_row)
    return [] unless res[:ok]
    boxes = res[:output].to_s.lines.map { |l| l.strip.split("\t") }.reject(&:empty?)
    @list_lock.synchronize { @list_cache[key] = {boxes: boxes, at: now} }
    boxes
  end

  def forget_box_list(box_row)
    @list_lock.synchronize { @list_cache.delete(box_row["id"]) }
  end

  # Proves the whole chain in one call: the key reaches the machine, its Docker
  # answers, and bay can read the config.
  def ping(box_row)
    res = bay(box_row, "list", timeout: 60)
    return res unless res[:ok]
    {ok: true, output: "pong #{box_row["host"]} bay=#{BAY}", exit_code: 0}
  end

  def list(box_row)
    res = bay(box_row, "list", timeout: 60)
    return res unless res[:ok]
    # name<TAB>branch<TAB>up?, the shape the sessions page already reads.
    rows = res[:output].lines.filter_map do |line|
      path, _sha, branch = line.split(/\s+/, 3)
      next unless path.to_s.include?("/.worktrees/")
      name = File.basename(path)
      ["#{name}\t#{branch.to_s.strip.delete("[]")}\tbox"].first
    end
    {ok: true, output: rows.join("\n"), exit_code: 0}
  end

  def teardown(box_row, box)
    return bad_box unless box.to_s.match?(BOX_RE)
    res = bay(box_row, "down", box, "--force", timeout: 300)
    FileUtils.rm_rf(state_dir(box_row["login"], box)) if res[:ok]
    res
  end

  def skills(box_row, _url)
    # The value lives in this user's bay.local.toml, which prepare! rewrites
    # from the database on every command. So storing it is the whole job.
    prepare!(box_row)
    {ok: true, output: "skills applied", exit_code: 0}
  rescue Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message}
  end

  # --- the long ones ---------------------------------------------------------
  # A review takes minutes, so it runs detached and the worker polls, exactly as
  # it did when the wrapper detached on the box. The difference is where the
  # state lives: here, on a persistent mount, next to the database that records
  # the same job.
  def review(box_row, repo:, pr_number:, box:)
    DevBox.validate!(repo: repo, pr_number: pr_number, box: box)
    raise Error, "the review prompt is missing at #{PROMPT}" unless File.size?(PROMPT)
    login = box_row["login"]
    dir = state_dir(login, box)
    state = File.join(dir, "state")
    if working?(dir)
      return {ok: false, output: "", exit_code: nil, error: "#{box} is already working"}
    end
    FileUtils.mkdir_p(dir)
    File.write(state, "building\n")
    File.write(File.join(dir, "log"), "")
    File.write(File.join(dir, "build.log"), "")

    prepare!(box_row)
    detach(box_row, dir, <<~SH)
      set -o pipefail
      "$BAY" up #{box} --pr #{pr_number} >> "$DIR/build.log" 2>&1 || { echo failed > "$DIR/state"; exit 1; }
      #{place_prompt(box_row, box)}
      echo reviewing > "$DIR/state"
      if "$BAY" run #{box} review >> "$DIR/log" 2>&1; then
        echo done > "$DIR/state"
      else
        echo failed > "$DIR/state"
      fi
    SH
    {ok: true, output: "started #{box}", exit_code: 0}
  rescue DevBox::Error, Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message}
  end

  def ask(box_row, box, prompt)
    return bad_box unless box.to_s.match?(BOX_RE)
    return {ok: false, output: "", exit_code: nil, error: "empty follow-up"} if prompt.to_s.strip.empty?
    login = box_row["login"]
    dir = state_dir(login, box)
    return {ok: false, output: "", exit_code: nil, error: "no review has run for #{box}"} unless Dir.exist?(dir)
    if working?(dir)
      return {ok: false, output: "", exit_code: nil, error: "that box is still working; wait for it to finish"}
    end

    prepare!(box_row)
    # Into the worktree on the machine, because the bay command reads it from
    # inside the container. Bounded: a prompt is a question, not a payload.
    placed = put_file(box_row, "#{worktree(box_row, box)}/.rq/followup.txt", prompt.to_s.byteslice(0, 8192))
    return placed unless placed[:ok]

    File.write(File.join(dir, "state"), "reviewing\n")
    File.open(File.join(dir, "log"), "a") { |f| f.write("\n--- follow-up ---\n#{prompt}\n") }
    detach(box_row, dir, <<~SH)
      if "$BAY" run #{box} ask >> "$DIR/log" 2>&1; then
        echo done > "$DIR/state"
      else
        echo failed > "$DIR/state"
      fi
    SH
    {ok: true, output: "asked #{box}", exit_code: 0}
  rescue Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message}
  end

  # --- helpers ---------------------------------------------------------------
  def worktree(box_row, box)
    repo = (box_row["repo_path"] || "ubicloud").to_s
    "#{repo}/.worktrees/#{box}"
  end

  # The review instructions travel with the app, so a box never has a stale
  # copy. They are placed after `bay up`, which is what creates the worktree.
  #
  # ssh is invoked as separate words. It used to be one "$SSH" variable holding
  # "ssh -F <path>", which bash reads as a single command name -- the copy never
  # ran, and `|| true` swallowed it, so the review started with no instructions
  # and claude answered "Input must be provided". A missing prompt fails the
  # review now, loudly, which is what the wrapper already did.
  def place_prompt(box_row, box)
    path = "#{worktree(box_row, box)}/.rq/review-prompt.md"
    remote = DevBox.sh_quote("mkdir -p #{DevBox.sh_quote(File.dirname(path))} && cat > #{DevBox.sh_quote(path)}")
    <<~SH.strip
      if ! ssh -F "$SSH_CFG" #{host_alias(box_row["login"])} #{remote} < "$PROMPT_FILE"; then
        echo "could not place the review prompt on the machine" >> "$DIR/build.log"
        echo failed > "$DIR/state"
        exit 1
      fi
    SH
  end

  # A small file onto the machine, over the same ssh bay uses. The path is
  # built here and quoted once; the bytes go on stdin so nothing in them is
  # ever parsed by a shell.
  def put_file(box_row, path, body)
    argv = ["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]),
            "mkdir -p #{DevBox.sh_quote(File.dirname(path))} && cat > #{DevBox.sh_quote(path)}"]
    capture(argv, env_for(box_row), timeout: 30, stdin: body)
  end

  def detach(box_row, dir, script)
    env = env_for(box_row).merge("DIR" => dir, "BAY" => BAY,
      "SSH_CFG" => ssh_config_path(box_row["login"]), "PROMPT_FILE" => PROMPT)
    pid = Process.spawn(env, "bash", "-c", script,
                        pgroup: true, unsetenv_others: true,
                        in: "/dev/null", out: File.join(dir, "spawn.log"),
                        err: [File.join(dir, "spawn.log"), "a"])
    File.write(File.join(dir, "pid"), "#{pid}\n")
    Process.detach(pid)
    pid
  end

  # Working means both: the state says so AND the process is still there. A box
  # that has never been reviewed has no state file at all, which is not an
  # error -- it is the normal first time.
  def working?(dir)
    state = File.read(File.join(dir, "state")).to_s.strip
    %w[building reviewing].include?(state) && alive?(dir)
  rescue Errno::ENOENT
    false
  end

  def alive?(dir)
    pid = File.read(File.join(dir, "pid")).to_i
    return false unless pid.positive?
    Process.kill(0, pid)
    true
  rescue StandardError
    false
  end

  def read_state(box_row, box)
    return bad_box unless box.to_s.match?(BOX_RE)
    dir = state_dir(box_row["login"], box)
    state = File.read(File.join(dir, "state")).to_s.strip
    # A detached run that died -- a redeploy, an OOM -- leaves the state word it
    # last wrote. Saying so is better than reporting work that is not happening.
    state = "failed" if %w[building reviewing].include?(state) && !alive?(dir)
    {ok: true, output: state.empty? ? "unknown" : state, exit_code: 0}
  rescue Errno::ENOENT
    {ok: true, output: "unknown", exit_code: 0}
  end

  def read_log(box_row, box, name, limit)
    return bad_box unless box.to_s.match?(BOX_RE)
    path = File.join(state_dir(box_row["login"], box), name)
    body = File.exist?(path) ? tail(path, limit) : ""
    {ok: true, output: body, exit_code: 0}
  end

  # Cut at a byte offset, then drop whatever partial character that split, or
  # Postgres refuses the whole write and the job wedges.
  def tail(path, limit)
    size = File.size(path)
    body = File.open(path, "rb") do |f|
      f.seek([size - limit, 0].max)
      f.read
    end
    body.to_s.force_encoding(Encoding::UTF_8).scrub("")
  end

  def write_file(path, body, mode)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(mode, path)
  end

  def write_private(path, body) = write_file(path, body, 0o600)

  def bad_box = {ok: false, output: "", exit_code: nil, error: "bad box name"}
end
