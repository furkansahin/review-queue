require "open3"
require "fileutils"
require "json"
require_relative "crypto"
require_relative "baybox"
require_relative "queue_service"
require_relative "stream_render"

# Drives bay from this host instead of from the user's box.
#
# bay already knows how to work a remote Docker host: DOCKER_HOST=ssh://<host>
# for containers, ssh for git and worktrees. So the dashboard runs bay, points
# it at the user's own machine, and the containers still live there. What used
# to be a shell wrapper installed on every baybox, with its own verbs and its
# own state files, is this file instead -- one copy, deployed with the app.
#
# Each user gets their own bay home, their own config, their own state. Nothing
# is shared between two users except the read-only tooling in bin/ and the
# repo's config folder, which is the same for everybody.
#
# The verbs kept their names through that move, so jobs.rb, worker.rb and the
# routes never had to learn a new vocabulary.
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
  PROMPT = ENV.fetch("RQ_REVIEW_PROMPT", File.join(__dir__, "baybox", "review-prompt.md"))

  BOX_RE = /\A[a-z0-9][a-z0-9-]{0,48}\z/

  def enabled? = File.executable?(BAY) && File.directory?(SHARED_CONFIG) && File.exist?(COMPOSE)

  # Why not, in a sentence, for the Baybox page to show.
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
    FileUtils.mkdir_p(repo_root(login))
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
  # --dangerously-skip-permissions, deliberately. A review runs unattended, and
  # claude -p cannot ask for permission, so without this it is denied anything
  # beyond read-only shell: the first real review reported "no test result in
  # this review is verified" because rspec, psql and ruby were all refused.
  # Running the specs is the whole point of the harness.
  #
  # What it is allowed to touch is a throwaway container on the user's own
  # machine, holding a worktree of one pull request and its own database. It is
  # torn down afterwards. The box's GitHub token is the real exposure, and it is
  # the same token that developer already uses there.
  PERMS = "--dangerously-skip-permissions"
  # Without this claude prints its whole answer at the end and nothing before,
  # so a twenty minute review showed nothing at all while it ran. stream-json
  # emits an event per step; StreamRender turns those into the trace the page
  # shows. --verbose is what makes it emit them one at a time.
  FORMAT = "--output-format stream-json --verbose"

  # Every run also writes its output to a file inside the box, and stamps the
  # exit code at the end.
  #
  # Measured: a command started with docker exec keeps running when its client
  # dies -- killed the client, the process carried on writing. So a deploy here
  # never killed a review, it only stopped anyone listening to it. The work went
  # on inside the box while the job was marked failed.
  #
  # This file is what makes that recoverable: the box holds the output, and the
  # stamp says whether the run finished and how. tee keeps the live stream
  # working exactly as before -- the same bytes still come back over bay.
  BOX_LOG = ".rq/run.log"
  EXIT_MARK = "__RQ_EXIT:"
  # Each run stamps its own beginning as well as its end.
  #
  # A follow-up appends to the same file, so yesterday's exit stamp was still
  # the last one in there when today's question started. The worker read it,
  # decided the run had already finished, and wrote back the review on its own
  # -- while the answer was still being written. An exit stamp only counts if
  # it comes after the newest start stamp.
  RUN_MARK = "__RQ_RUN__"

  def self.wrapped(command, truncate:, preamble: nil, stamp: true)
    reset = truncate ? " && : > #{BOX_LOG}" : ""
    mark = stamp ? %( && echo "#{RUN_MARK}" >> #{BOX_LOG}) : ""
    say = preamble ? "#{preamble}; " : ""
    %(mkdir -p .rq#{reset}#{mark} && ) +
      %({ #{say}#{command}; echo "#{EXIT_MARK}$?"; } 2>&1 | tee -a #{BOX_LOG})
  end

  REVIEW_CMD = wrapped(
    %(claude -p --model opus --effort max #{PERMS} #{FORMAT} -- "$(cat .rq/review-prompt.md)"),
    truncate: true)
  # The question is echoed into the run, so the trace says what was asked. It
  # used to be written only to this host's copy of the log, which adopting then
  # replaced with the box's -- so the question vanished from the page while the
  # answer to it stayed.
  # No start stamp in this one: ask writes it from the dashboard, before the
  # run is detached. See mark_run.
  ASK_CMD = wrapped(
    %(claude -p --continue --model opus --effort max #{PERMS} #{FORMAT} -- "$(cat .rq/followup.txt)"),
    truncate: false, stamp: false,
    preamble: %(printf '\\n== you asked\\n%s\\n\\n' "$(cat .rq/followup.txt)"))

  # bay decides where a synced file lands by comparing the config folder to the
  # repo root: files from the config folder go to the box's <repo>/.bay/, and
  # everything else to the repo root. With no repoPath the root falls back to
  # the config folder itself, the two are equal, and post-create.sh was rsynced
  # to the top of the checkout -- where the setup step, which looks in .bay/,
  # could not find it. A box that already had a .bay from the old by-hand setup
  # hid this; a fresh one could not build at all.
  #
  # There is no checkout on this host and none is wanted, so this is an empty
  # directory whose only job is to be somewhere else.
  def repo_root(login) = File.join(user_dir(login), "repo")

  def local_toml(box_row)
    lines = ["# Written by review-queue. Edits here are overwritten.",
             %(repoPath = #{repo_root(box_row["login"]).inspect}),
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
  # One word per thing a caller can ask for, so the worker and the routes read
  # the same whatever is underneath.
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
    BayBox.validate!(repo: repo, pr_number: pr_number, box: box)
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
    align_pr_branch(box_row, repo, pr_number)
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
  rescue BayBox::Error, Error, Crypto::Error => e
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

    # Stamp the new run here, not inside the box.
    #
    # The command in the box writes its own stamp, but not for a second or two:
    # bay has to reach the machine and exec into the container first. The worker
    # polls inside that gap, finds no stamp newer than the last run's, reads the
    # previous run's exit stamp as this one's, and calls a question that has
    # only just been asked already answered -- with the answer to the last one.
    #
    # A review does not need this: the worker starts it, so the worker can see
    # its process and never treats it as lost in the first place.
    stamped = mark_run(box_row, box)
    return stamped unless stamped[:ok]

    File.write(File.join(dir, "state"), "reviewing\n")
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

  # Takes back a run this host lost track of -- a deploy, a restart, an OOM.
  # The box kept writing, so its copy is the truth: pull it, and read the stamp
  # at the end to know whether it is finished.
  def adopt(box_row, box)
    return bad_box unless box.to_s.match?(BOX_RE)
    path = "#{worktree(box_row, box)}/#{BOX_LOG}"
    res = capture(["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]),
                   "cat #{BayBox.sh_quote(path)} 2>/dev/null || true"],
                  env_for(box_row), timeout: 60)
    return res.merge(finished: false) unless res[:ok]

    text = res[:output].to_s
    # Only this run's stamps count. The file holds every run for this box.
    started = text.rindex(RUN_MARK)
    scope = started ? text[(started + RUN_MARK.length)..] : text
    mark = scope.rindex(EXIT_MARK)
    finished = !mark.nil?
    code = finished ? scope[(mark + EXIT_MARK.length)..].to_i : nil
    # The body is the whole file, not just this run: a follow-up is read
    # together with the review it follows. The renderer knows the stamps and
    # turns them into boundaries the page can split on.
    raw = text
    body = StreamRender.all(raw)

    # Keep this host in step, so the page and the worker read the same thing
    # and the live log carries on from where it stopped.
    dir = state_dir(box_row["login"], box)
    FileUtils.mkdir_p(dir)
    # The events, not the rendering: this file is the raw record, and the live
    # stream renders it as it reads.
    File.write(File.join(dir, "log"), raw)
    File.write(File.join(dir, "state"),
      finished ? (code.to_i.zero? ? "done\n" : "failed\n") : "reviewing\n")
    {ok: true, finished: finished, exit_code: code, output: body}
  rescue Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message, finished: false}
  end

  # bay checks a pull request out with `gh pr checkout`, which updates a local
  # branch named after the pull request's own head branch. A previous review of
  # the same pull request leaves that branch behind, so once the author force
  # pushes, the update is no longer a fast forward and bay up stops dead:
  #
  #   ! [rejected] refs/pull/5886/head -> gcp-service-account-mode (non-fast-forward)
  #
  # Move the branch to where the pull request is now, before bay looks at it.
  # Only when it has actually diverged, and never when it is checked out
  # somewhere -- a branch someone is working on is left alone, and bay reports
  # the real error rather than this quietly rewriting it.
  #
  # Best effort on purpose: a review whose branch needs no repair must not fail
  # because GitHub was slow. If the repair was needed and did not happen, bay
  # says so in its own words a moment later.
  def align_pr_branch(box_row, repo, pr_number)
    token = decrypt_or_nil(box_row["github_token_enc"])
    return unless token
    pull = GitHubClient.new(token).try("/repos/#{repo}/pulls/#{pr_number}")
    ref = pull && pull.dig("head", "ref").to_s
    # A branch name reaches a shell on the box, so it is checked, not quoted
    # away: git's own rules are narrower than this and anything else is a sign
    # something is wrong.
    return if ref.to_s.empty? || !ref.match?(%r{\A[A-Za-z0-9._/-]{1,200}\z}) || ref.include?("..")

    path = (box_row["repo_path"] || "ubicloud").to_s
    script = <<~SH
      cd #{BayBox.sh_quote(path)} || exit 0

      # A branch lives in one worktree at a time. If the base clone is sitting
      # on the very branch this review needs, the review's own worktree cannot
      # have it, and bay stops with:
      #   refusing to fetch into branch '...' checked out at '/workspace'
      # A previous review leaves it there, so put the base clone back on its
      # base branch first. git carries uncommitted work across, and if it
      # cannot, this gives up rather than forcing anything.
      if [ "$(git symbolic-ref --quiet --short HEAD)" = #{BayBox.sh_quote(ref)} ]; then
        base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
        base=${base#origin/}
        git checkout --quiet "${base:-main}" 2>/dev/null \
          && echo "moved the base clone off #{ref}" \
          || echo "the base clone is on #{ref} and would not move"
      fi

      git rev-parse --verify --quiet refs/heads/#{ref} >/dev/null || exit 0
      git fetch -q origin refs/pull/#{pr_number}/head || exit 0
      git merge-base --is-ancestor refs/heads/#{ref} FETCH_HEAD && exit 0
      [ -n "$(git for-each-ref --format='%(worktreepath)' refs/heads/#{ref})" ] && exit 0
      git update-ref refs/heads/#{ref} FETCH_HEAD
      echo "moved #{ref} to the pull request head"
    SH
    capture(["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]), script],
            env_for(box_row), timeout: 60)
  rescue StandardError
    nil
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
  # review now, loudly, rather than running it blind.
  def place_prompt(box_row, box)
    path = "#{worktree(box_row, box)}/.rq/review-prompt.md"
    remote = BayBox.sh_quote("mkdir -p #{BayBox.sh_quote(File.dirname(path))} && cat > #{BayBox.sh_quote(path)}")
    <<~SH.strip
      if ! ssh -F "$SSH_CFG" #{host_alias(box_row["login"])} #{remote} < "$PROMPT_FILE"; then
        echo "could not place the review prompt on the machine" >> "$DIR/build.log"
        echo failed > "$DIR/state"
        exit 1
      fi
    SH
  end

  # Everything a box needs, done from here.
  #
  # Since bay moved to the dashboard a box needs three things: this key in its
  # authorized_keys, docker, and a checkout. The key is the one that cannot be
  # automated -- it is what grants the access everything else would use. The
  # other two are just commands, and the dashboard can already reach the
  # machine, so it runs them.
  #
  # Idempotent: it checks before it installs, so pressing the button twice is
  # the same as pressing it once, and a box that is already set up says so
  # rather than reinstalling anything.
  REPO_URL = ENV.fetch("RQ_REPO_URL", "https://github.com/ubicloud/ubicloud.git")

  def prepare_box(box_row)
    path = (box_row["repo_path"] || "ubicloud").to_s
    script = <<~SH
      set -u
      say()  { echo "  $*"; }
      # Every step is checked. Without this the script ran on past a failed
      # apt-get, printed "docker installed ()" with no version, failed to add a
      # group that was never created, cloned, and finished by saying "ready" --
      # and the exit status was the last command's, so it reported success.
      fail() { echo "  $*"; exit 1; }

      # One preparation at a time. Pressing the button twice used to start a
      # second apt-get against the first one's dpkg lock, and both then failed
      # on a machine that was working perfectly well.
      exec 9>"$HOME/.rq-prepare.lock"
      if ! flock -n 9; then
        fail "already preparing this box; give it a few minutes"
      fi

      if command -v docker >/dev/null 2>&1; then
        say "docker already installed ($(docker --version 2>/dev/null))"
      else
        sudo -n true 2>/dev/null || fail "cannot install docker: this user needs sudo without a password"
        say "installing docker from its own repository (a few minutes)"
        sudo apt-get update -qq || fail "apt-get update failed"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl \
          || fail "could not install ca-certificates and curl"
        sudo install -m 0755 -d /etc/apt/keyrings || fail "could not create /etc/apt/keyrings"
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
          || fail "could not fetch docker's signing key"
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
          "$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")" \
          "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null \
          || fail "could not add docker's apt source"
        sudo apt-get update -qq || fail "apt-get update failed after adding docker's source"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
          || fail "could not install docker"
        command -v docker >/dev/null 2>&1 || fail "apt-get finished but docker is still not on PATH"
        say "docker installed ($(docker --version 2>/dev/null))"
      fi

      # Installing docker is not enough: without the group every docker command
      # needs sudo, and the dashboard does not use sudo. The daemon then reads
      # as unreachable when it is running perfectly well.
      if id -nG | grep -qw docker; then
        say "$(id -un) can reach docker"
      else
        getent group docker >/dev/null || fail "there is no docker group; the install did not finish"
        sudo -n true 2>/dev/null || fail "$(id -un) is not in the docker group, and sudo needs a password"
        sudo usermod -aG docker "$(id -un)" || fail "could not add $(id -un) to the docker group"
        say "added $(id -un) to the docker group"
      fi

      if [ -d #{BayBox.sh_quote(path)}/.git ]; then
        say "checkout already at ~/#{path}"
      else
        say "cloning #{REPO_URL}"
        git clone --quiet #{BayBox.sh_quote(REPO_URL)} #{BayBox.sh_quote(path)} \
          || fail "could not clone #{REPO_URL}"
        say "cloned into ~/#{path}"
      fi

      # A first review builds a container image, which is where the disk goes.
      avail=$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1048576)}')
      say "${avail}G free (a box costs about 7G)"
      say "ready"
    SH
    argv = ["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]), script]
    prepare!(box_row)
    capture(argv, env_for(box_row), timeout: Integer(ENV.fetch("RQ_PREPARE_TIMEOUT", "420")))
  rescue Error, Crypto::Error => e
    {ok: false, output: "", exit_code: nil, error: e.message}
  end

  # Opens a new run in the box's log, so nothing reads the previous one as this
  # one. Appends rather than writes: the log is the record of every run.
  def mark_run(box_row, box)
    path = "#{worktree(box_row, box)}/#{BOX_LOG}"
    argv = ["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]),
            "mkdir -p #{BayBox.sh_quote(File.dirname(path))} && " \
            "echo #{BayBox.sh_quote(RUN_MARK)} >> #{BayBox.sh_quote(path)}"]
    capture(argv, env_for(box_row), timeout: 30)
  end

  # A small file onto the machine, over the same ssh bay uses. The path is
  # built here and quoted once; the bytes go on stdin so nothing in them is
  # ever parsed by a shell.
  def put_file(box_row, path, body)
    argv = ["ssh", "-F", ssh_config_path(box_row["login"]), host_alias(box_row["login"]),
            "mkdir -p #{BayBox.sh_quote(File.dirname(path))} && cat > #{BayBox.sh_quote(path)}"]
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

  # The state word, exactly as the run itself wrote it. No liveness check: see
  # read_state for why that cannot be done from just anywhere.
  def state_word(login, box)
    return nil unless box.to_s.match?(BOX_RE)
    state = File.read(File.join(state_dir(login, box), "state")).to_s.strip
    state.empty? ? nil : state
  rescue Errno::ENOENT
    nil
  end

  # The worker's view, which is the one that decides a job's fate.
  #
  # A detached run that died -- a redeploy, an OOM -- leaves behind the state
  # word it last wrote, so the pid is checked as well. That check is only valid
  # in the process that spawned it: web and worker are separate containers with
  # separate pid namespaces, and the web container asking about the worker's
  # child gets ESRCH for every healthy review. It did, and the live log called
  # a running review failed.
  def read_state(box_row, box)
    return bad_box unless box.to_s.match?(BOX_RE)
    dir = state_dir(box_row["login"], box)
    state = state_word(box_row["login"], box)
    # Not "failed": the run itself never said so, and it may well still be
    # going inside the box. The worker adopts it rather than giving up on it.
    state = "orphaned" if %w[building reviewing].include?(state) && !alive?(dir)
    {ok: true, output: state || "unknown", exit_code: 0}
  end

  # The live log, as a path. With bay running here the review writes straight to
  # this host, so a page can read it directly instead of waiting for the worker
  # to notice and copy it into the database.
  def log_path(login, box)
    return nil unless box.to_s.match?(BOX_RE)
    path = File.join(state_dir(login, box), "log")
    File.exist?(path) ? path : nil
  end

  def read_log(box_row, box, name, limit)
    return bad_box unless box.to_s.match?(BOX_RE)
    path = File.join(state_dir(box_row["login"], box), name)
    body = File.exist?(path) ? tail(path, limit) : ""
    # The log holds claude's raw events. Rendering happens on the way out, so
    # the stored events stay whole and can be read differently later.
    body = StreamRender.all(body) if name == "log"
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
