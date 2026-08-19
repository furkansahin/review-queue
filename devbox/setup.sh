#!/usr/bin/env bash
# Prepare a dev box to accept reviews from the review-queue dashboard.
# Run it ON the dev box, as the user the dashboard will connect as (e.g. ubi).
#
#   ./setup.sh            check and install what it can
#   ./setup.sh --check    report only, change nothing
set -euo pipefail

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

REPO_URL="${RQ_REPO_URL:-https://github.com/ubicloud/ubicloud.git}"
REPO_PATH="${RQ_REPO_PATH:-$HOME/ubicloud}"
BAY_CONFIG="${RQ_BAY_CONFIG:-$HOME/.bay/ubicloud}"
BAY_CONFIG_URL="${RQ_BAY_CONFIG_URL:-git@github.com:ubicloud/bay-ubicloud.git}"
BAY="${RQ_BAY:-$HOME/go/bin/bay}"

ok()   { printf "  ok    %s\n" "$1"; }
todo() { printf "  TODO  %s\n" "$1"; MISSING=$((MISSING+1)); }
act()  { $CHECK_ONLY && { todo "$1"; return 1; }; printf "  ..    %s\n" "$1"; return 0; }
MISSING=0

echo "== tools =="
command -v git    >/dev/null && ok "git" || todo "install git"
command -v docker >/dev/null && ok "docker" || todo "install docker (bay drives docker compose)"
command -v script >/dev/null && ok "script (util-linux, supplies the tty bay run needs)" \
                              || todo "install util-linux for script(1)"
if command -v docker >/dev/null; then
  docker info >/dev/null 2>&1 && ok "docker usable without sudo" \
    || todo "add $USER to the docker group: sudo usermod -aG docker $USER (then log in again)"
fi

echo "== bay =="
if [ -x "$BAY" ]; then ok "bay at $BAY"
elif command -v go >/dev/null; then
  act "installing bay with go install" && go install github.com/ubicloud/bay@latest && ok "bay installed"
else
  todo "install Go, then: go install github.com/ubicloud/bay@latest"
fi

echo "== checkouts =="
if [ -d "$REPO_PATH/.git" ]; then ok "checkout at $REPO_PATH"
else
  act "cloning $REPO_URL to $REPO_PATH" && git clone "$REPO_URL" "$REPO_PATH" && ok "cloned"
fi
if [ -d "$BAY_CONFIG" ]; then ok "bay config at $BAY_CONFIG"
else
  todo "clone the bay config (private repo, needs your GitHub access):
          git clone $BAY_CONFIG_URL $BAY_CONFIG"
fi

echo "== bay config =="
# bay runs HERE, against this machine's own docker, so [remote] host must be
# unset. If it is set, bay would try to drive another machine over ssh.
if [ -f "$BAY_CONFIG/bay.local.toml" ] && grep -qE '^\s*host\s*=' "$BAY_CONFIG/bay.local.toml"; then
  todo "remove 'host =' from $BAY_CONFIG/bay.local.toml — bay runs on this box, against local docker"
else
  ok "no [remote] host set (bay uses this box's docker)"
fi

echo "== tokens =="
if [ -f "$HOME/.bay/env" ]; then
  grep -q CLAUDE_CODE_OAUTH_TOKEN "$HOME/.bay/env" && ok "CLAUDE_CODE_OAUTH_TOKEN present" \
    || todo "add CLAUDE_CODE_OAUTH_TOKEN to ~/.bay/env  (get it with: claude setup-token)"
  grep -q GITHUB_TOKEN "$HOME/.bay/env" && ok "GITHUB_TOKEN present" \
    || todo "add GITHUB_TOKEN to ~/.bay/env  (a PAT with contents:write, so the box can push)"
else
  todo "create ~/.bay/env with CLAUDE_CODE_OAUTH_TOKEN and GITHUB_TOKEN"
fi

echo "== the dashboard's wrapper =="
if [ -x /usr/local/bin/rq-review ]; then ok "/usr/local/bin/rq-review installed"
else
  todo "sudo install -m 0755 rq-review /usr/local/bin/rq-review"
fi
if grep -q "rq-review" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  ok "a forced-command key is in authorized_keys"
else
  todo "paste the key line from the dashboard's Dev box page into ~/.ssh/authorized_keys"
fi

echo "== disk =="
avail=$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1048576)}')
[ "${avail:-0}" -ge 20 ] && ok "${avail}G free (each box is containers + a worktree + a postgres)" \
                         || todo "only ${avail}G free; each review box needs a few GB"

echo
if [ "$MISSING" -eq 0 ]; then
  echo "Ready. Press Review in the dashboard."
else
  echo "$MISSING thing(s) still to do."
  exit 1
fi
