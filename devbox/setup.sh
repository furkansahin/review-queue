#!/usr/bin/env bash
# Prepare a dev box to accept reviews from the review-queue dashboard.
# Run ON the dev box, as the user the dashboard will connect as (e.g. ubi).
#
#   ./setup.sh            install and configure what it can
#   ./setup.sh --check    report only, change nothing
#
# Verified end to end on a fresh Ubuntu 24.04 Ubicloud VM (2 vcpu, 7G).
# A cold box took 335s to reach "ready"; see README.md for the numbers.
set -uo pipefail

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

REPO_URL="${RQ_REPO_URL:-https://github.com/ubicloud/ubicloud.git}"
REPO_PATH="${RQ_REPO_PATH:-$HOME/ubicloud}"
BAY_CONFIG="${RQ_BAY_CONFIG:-$HOME/.bay/ubicloud}"
BAY_SRC="${RQ_BAY_SRC:-}"          # a directory holding bay's source, if you have one
BAY="${RQ_BAY:-$HOME/go/bin/bay}"
SELF_HOST="${RQ_SELF_HOST:-bayself}"

MISSING=0
ok()   { printf "  ok    %s\n" "$1"; }
todo() { printf "  TODO  %s\n" "$1"; MISSING=$((MISSING+1)); }
doing(){ printf "  ..    %s\n" "$1"; }
can_change() { ! $CHECK_ONLY; }

echo "== packages =="
NEED=()
for c in git rsync script curl; do command -v "$c" >/dev/null || NEED+=("$c"); done
# rsync matters: bay uses it to deliver post-create.sh and bin/ into the box.
# script(1) supplies the tty that `bay run` needs, because it execs without -T.
if [ ${#NEED[@]} -eq 0 ]; then
  ok "git, rsync, script, curl"
elif can_change; then
  doing "installing ${NEED[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git rsync util-linux curl >/dev/null && ok "installed"
else
  todo "apt-get install ${NEED[*]}"
fi

echo "== docker =="
if command -v docker >/dev/null; then
  ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
elif can_change; then
  doing "installing docker from the official repository"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null && ok "docker installed"
  sudo usermod -aG docker "$USER"
  ok "added $USER to the docker group (needs a new login to take effect)"
else
  todo "install docker"
fi
docker info >/dev/null 2>&1 && ok "docker usable without sudo" \
  || todo "log out and back in so the docker group applies (or: sg docker -c ...)"

echo "== bay =="
if [ -x "$BAY" ]; then
  ok "bay at $BAY"
elif [ -n "$BAY_SRC" ] && [ -d "$BAY_SRC" ] && can_change; then
  # NOTE: `go install github.com/ubicloud/bay@latest` (bay's README) does NOT
  # work on a clean machine: bay is a private repo and go has no credentials.
  # bay vendors its dependencies, so building from a source copy needs no network.
  doing "building bay from $BAY_SRC"
  command -v go >/dev/null || {
    GO_VER=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
    curl -fsSL "https://go.dev/dl/${GO_VER}.linux-$(dpkg --print-architecture).tar.gz" -o /tmp/go.tgz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
  }
  export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH
  mkdir -p "$(dirname "$BAY")"
  (cd "$BAY_SRC" && GOFLAGS=-mod=vendor go build -o "$BAY" .) && ok "bay built"
else
  todo "bay is a private repo, so go install cannot fetch it.
          Bake the binary into the image, or set RQ_BAY_SRC to a source copy."
fi

echo "== checkouts =="
if [ -d "$REPO_PATH/.git" ]; then
  ok "checkout at $REPO_PATH"
elif can_change; then
  doing "cloning $REPO_URL"
  git clone -q "$REPO_URL" "$REPO_PATH" && ok "cloned"
else
  todo "git clone $REPO_URL $REPO_PATH"
fi
[ -f "$BAY_CONFIG/bay.toml" ] && ok "bay config at $BAY_CONFIG" \
  || todo "bay config missing (private repo): git clone git@github.com:ubicloud/bay-ubicloud.git $BAY_CONFIG"

echo "== bay must treat this box as its remote =="
# bay's syncToHost is a no-op unless [remote] host is set: it assumes a local
# setup keeps its config in-repo. Ours is out of tree, so without a host the
# tooling never reaches the box and setup dies on
#   bash: /workspace/.bay/post-create.sh: No such file or directory
# Pointing bay at this same machine over ssh puts it back on its supported path.
if [ ! -f "$HOME/.ssh/id_bayself" ] && can_change; then
  doing "creating a loopback ssh key so bay can reach this box"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_bayself" -N "" -C bay-self >/dev/null
fi
if [ -f "$HOME/.ssh/id_bayself.pub" ]; then
  grep -qF "$(cat "$HOME/.ssh/id_bayself.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null \
    || { can_change && cat "$HOME/.ssh/id_bayself.pub" >> "$HOME/.ssh/authorized_keys"; }
  if ! grep -q "Host $SELF_HOST" "$HOME/.ssh/config" 2>/dev/null && can_change; then
    printf 'Host %s\n  HostName 127.0.0.1\n  User %s\n  IdentityFile ~/.ssh/id_bayself\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' \
      "$SELF_HOST" "$USER" >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
fi
ssh -n -o BatchMode=yes "$SELF_HOST" true 2>/dev/null && ok "ssh $SELF_HOST works" || todo "the box cannot ssh to itself as $SELF_HOST"
if [ -f "$BAY_CONFIG/bay.toml" ]; then
  if grep -qE "^\s*host\s*=\s*\"$SELF_HOST\"" "$BAY_CONFIG/bay.local.toml" 2>/dev/null; then
    ok "bay.local.toml points at $SELF_HOST"
  elif can_change; then
    printf '[remote]\nhost = "%s"\n' "$SELF_HOST" > "$BAY_CONFIG/bay.local.toml"
    ok "wrote bay.local.toml pointing at $SELF_HOST"
  else
    todo "set [remote] host = \"$SELF_HOST\" in $BAY_CONFIG/bay.local.toml"
  fi
fi

echo "== tokens (never baked into an image: these are per person) =="
if [ -f "$HOME/.bay/env" ]; then
  grep -q "CLAUDE_CODE_OAUTH_TOKEN=." "$HOME/.bay/env" && ok "CLAUDE_CODE_OAUTH_TOKEN set" \
    || todo "add CLAUDE_CODE_OAUTH_TOKEN to ~/.bay/env   (get it with: claude setup-token)"
  # gh needs a token even for a public repo, because --pr uses gh pr checkout
  grep -q "GITHUB_TOKEN=." "$HOME/.bay/env" && ok "GITHUB_TOKEN set" \
    || todo "add GITHUB_TOKEN to ~/.bay/env   (Contents: Read is enough for --pr)"
else
  todo "create ~/.bay/env with CLAUDE_CODE_OAUTH_TOKEN and GITHUB_TOKEN"
fi

echo "== the dashboard's wrapper =="
[ -x /usr/local/bin/rq-review ] && ok "/usr/local/bin/rq-review installed" \
  || todo "sudo install -m 0755 rq-review /usr/local/bin/rq-review"
grep -q "rq-review" "$HOME/.ssh/authorized_keys" 2>/dev/null && ok "forced-command key present" \
  || todo "paste the key line from the dashboard's Dev box page into ~/.ssh/authorized_keys"

echo "== capacity =="
avail=$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1048576)}')
# measured: one box costs about 7G with its container images and a postgres
[ "${avail:-0}" -ge 20 ] && ok "${avail}G free (about $((avail / 7)) boxes)" \
                         || todo "only ${avail}G free; a box needs about 7G"

echo
if [ "$MISSING" -eq 0 ]; then
  echo "Ready. Try:  cd $REPO_PATH && bay doctor"
else
  echo "$MISSING thing(s) still to do."
  exit 1
fi
