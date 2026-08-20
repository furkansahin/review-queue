# Dev box setup

## From a fresh Ubuntu 24.04 VM

**1. Put your two tokens on the box.** These stay there and never reach the
dashboard. Everything else needs them, because bay and its config are both
private repositories.

```sh
mkdir -p ~/.bay && cat > ~/.bay/env <<'EOF'
CLAUDE_CODE_OAUTH_TOKEN=...   # from: claude setup-token
GITHUB_TOKEN=...              # see the scope note below
EOF
chmod 600 ~/.bay/env
```

**2. Run the setup script.**

```sh
curl -fsSL https://raw.githubusercontent.com/furkansahin/review-queue/main/devbox/setup.sh -o setup.sh
bash setup.sh            # or: bash setup.sh --check  to look first
```

It installs docker, clones and builds bay, clones the bay config and the
ubicloud checkout, points bay at this box over loopback ssh, and installs the
wrapper.

**3. Paste the key line** from the dashboard's Dev box page into
`~/.ssh/authorized_keys`, then press **Test connection**. It should answer
`pong <hostname>`.

That is the whole setup: two tokens, one script, one paste.

## The GITHUB_TOKEN needs three repositories

A fine-grained PAT lists repositories **explicitly**, so one that works for the
queue can still fail to fetch bay. Give it **Contents: Read** on all three:

| Repository | Needed for |
| --- | --- |
| `ubicloud/ubicloud` | the checkout, and `gh pr checkout` for `--pr` |
| `ubicloud/bay` | building the bay binary |
| `ubicloud/bay-ubicloud` | the bay config |

`setup.sh` checks all three before it does anything and names the one that is
missing. A missing `ubicloud/bay` is what produces:

```
rq-review: bay not found. Looked in: ...
```

## Why bay has to be built rather than installed

`go install github.com/ubicloud/bay@latest`, the command in bay's own README,
fails on a clean machine: bay is a private repository and go has no
credentials. The script clones it with your `GITHUB_TOKEN` and builds from the
vendored dependencies, which needs no further network access.

## Why bay is pointed at this box over loopback ssh

bay's `syncToHost` is a no-op unless `[remote] host` is set — it assumes a local
setup keeps its config in the repo. Ours is out of tree, so without a host the
tooling never reaches the box and setup dies on

```
bash: /workspace/.bay/post-create.sh: No such file or directory
```

Pointing bay at this same machine over `127.0.0.1` puts it back on its supported
path. `bay doctor` then runs 8 checks instead of 4.

## Making boxes fast

Out of the box a box takes about 330s. See `base-image/README.md`: one setting
takes it to 144s, and a prebaked image takes it to **66s**.

```sh
bash setup.sh --build-base-image
```

## Do not copy bay.local.toml between machines

It is per-machine and gitignored for a reason. Copying one carries settings that
do not apply, and a `baseImage` naming an image the new box has never built
fails at `bay up` with:

```
pull access denied, repository does not exist or may require authorization
```

because bay asks Docker to pull a local-only tag from Docker Hub. `setup.sh`
now checks for exactly this and offers to build the image or tells you to drop
the line.

## What the dashboard's key can do

The wrapper is the only thing it may run, pinned by `command=` in
`authorized_keys` with `restrict`. It accepts seven verbs — `ping`, `review`,
`status`, `result`, `build`, `list`, `teardown` — validates every field against
a strict pattern, and never passes anything to `eval`. A stolen key can start
reviews on this box and nothing else.

## Files here

| File | Role |
| --- | --- |
| `setup.sh` | prepares a dev box; `--check` reports without changing anything |
| `rq-review` | the forced-command wrapper the dashboard talks to |
| `test_wrapper.sh` | 18 injection cases against the wrapper |
| `bay-review-command.toml` | the `[commands] review` entry for bay-ubicloud |
| `install-skills.sh` | carries a developer's own Claude skills into a box |
| `base-image/` | prebaked image, and the measurements behind it |
