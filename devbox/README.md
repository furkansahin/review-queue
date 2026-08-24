# Dev box setup

A dev box is a machine of your own that runs the review containers. The
dashboard drives it: bay runs on the dashboard and points at this machine's
Docker over ssh, so the box itself needs very little.

**Three things, and no more:**

1. the dashboard's key in `~/.ssh/authorized_keys`
2. docker, with your ssh user able to use it
3. a checkout of the repository

The box does *not* need bay, a wrapper, a bay config, or a token file. Those
all lived here before the dashboard took bay over. If your box still has them,
they are inert; you can delete `~/go/bin/bay`, `/usr/local/bin/rq-review` and
`~/.bay/` whenever you like.

## From a fresh Ubuntu 24.04 VM

**1. Register the box** on the dashboard's Dev box page: its address, your ssh
user, and where the checkout should live. Paste in your Claude token (from
`claude setup-token` on your own machine) and a GitHub PAT that can read the
repository. Both are encrypted with the same key as your ssh key and are never
shown back.

**2. Paste the key line** the page shows into `~/.ssh/authorized_keys` on the
box. This is the only step that cannot be automated — it is what grants the
access everything else uses.

**3. Press "Prepare this box".** It installs docker, adds your ssh user to the
docker group, and clones the repository. A few minutes the first time. It is
idempotent: pressing it twice is pressing it once.

Then press **Test connection**. It should answer `pong <address>`.

### Doing step 3 by hand instead

If you are already sitting on the machine:

```sh
curl -fsSL https://raw.githubusercontent.com/furkansahin/review-queue/main/devbox/setup.sh -o setup.sh
bash setup.sh --check    # look first
bash setup.sh            # then do it
```

Same work, same checks. It refuses to run on anything that is not Linux unless
`RQ_FORCE_HOST=1`, because it changes the machine it runs on.

Installing docker needs `sudo` without a password. Both the button and the
script check that first and say so, rather than stopping half way through an
apt run.

## The docker group

This is the step that is easy to miss by hand. Installing docker is not enough:
without being in the `docker` group your user cannot reach the daemon, and the
dashboard does not use `sudo`. The failure reads as though the daemon is down
when it is not:

```
Cannot connect to the Docker daemon at http://docker.example.com.
```

Group membership is picked up at login, so the next connection has it.

## Tokens

Both live on the dashboard now, per user, encrypted at rest.

- **Claude** — `claude setup-token` on your own machine, then paste it in. bay
  writes it into each box as it builds one.
- **GitHub** — a PAT with `Contents: Read` on the repository you review. The
  clone itself is over https on a public repository and needs nothing, but the
  box uses the token for `gh pr checkout` and for pushing from a review.

## Skills

Set a skills repository on the Dev box page and bay clones it into every new
box's `~/.claude/skills`, pulling it on later starts. It is cloned inside the
box with that box's own GitHub token, so a private repository works and the
dashboard never reads it.

## Capacity

A box costs about 7G once its images and database are there. `setup.sh` reports
free space and how many boxes that is.

## What is in this directory

| file | what it is |
| --- | --- |
| `setup.sh` | prepares a dev box by hand; `--check` reports without changing anything |
| `review-prompt.md` | the review instructions, copied into a box at review time |
| `install-host.sh` | installs bay and its config on the **dashboard** host, not here |
| `base-image` | an optional prebaked box image; see below |
| `rq-review`, `test_wrapper.sh`, `bay-review-command.toml`, `install-skills.sh` | from before the dashboard ran bay. Kept for `RQ_TRANSPORT=ssh`, unused otherwise |

### The base image

A cold box builds in about five minutes; one built from a prebaked image takes
about one. The image is built on the box and named by `RQ_BOX_BASE_IMAGE`,
which the dashboard writes into each user's bay config. See `base-image/`.
