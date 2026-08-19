# Dev box setup

Two things go on each user's dev box. The dashboard shows both, filled in, on
its settings page.

## 1. The wrapper

```sh
sudo install -m 0755 rq-review /usr/local/bin/rq-review
```

It is the only thing the dashboard's key may run. It accepts five verbs —
`ping`, `review`, `status`, `result`, `teardown` — and refuses everything else.
Every field is matched against a strict pattern before it is used, and nothing
is ever passed to `eval`.

Defaults it assumes, all overridable by environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RQ_ALLOWED_REPOS` | `ubicloud/ubicloud` | repositories this box will review |
| `RQ_REPO_PATH` | `$HOME/ubicloud` | the checkout bay runs from |
| `RQ_BAY` | `$HOME/go/bin/bay` | the bay binary |
| `RQ_STATE_DIR` | `$HOME/.rq` | where job state and logs live |

## 2. The key

Paste the line the dashboard gives you into `~/.ssh/authorized_keys`:

```
command="/usr/local/bin/rq-review",restrict ssh-rsa AAAA... review-queue
```

`command=` forces the wrapper whatever the dashboard sends. `restrict` turns off
port forwarding, agent forwarding, X11 and a pty. So the key cannot become a
shell even if the dashboard is fully compromised: it can start reviews on this
box and nothing else.

## 3. The bay command

Add the `[commands] review` entry from `bay-review-command.toml` to
`bay-ubicloud`'s `bay.toml`. `bay run` only executes commands defined in the
config, so the dashboard cannot pass a prompt — and does not need to, because
`bay up <box> --pr <n>` already checked the worktree out at the pull request.

## How a review runs

```
dashboard --ssh--> rq-review review <repo> <pr> <box>
                     └─ detaches, returns at once
                        bay up <box> --pr <pr>
                        bay run <box> review        (claude -p, adversarial)
dashboard --ssh--> rq-review status <box>     queued -> running -> done|failed
dashboard --ssh--> rq-review result <box>     the review text
```

A review takes minutes, so the wrapper detaches with `setsid` and the dashboard
polls. Losing the connection does not lose the job.

## One thing to fix in bay

`bay run` calls `dockerExec(interactive: true)`, which omits `-T`, so
`docker compose exec` demands a tty. Over a plain `ssh host 'cmd'` there is no
tty and it fails, so the wrapper wraps it in `script -qec` to supply one.

A `--no-tty` flag on `bay run` (or `dockerExec(false, …)` for non-interactive
commands) would remove that workaround. It is a one-line change in `bay`, and
worth making if the dashboard is not the only thing that ever drives bay
non-interactively.
