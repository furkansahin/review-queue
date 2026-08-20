#!/usr/bin/env bash
# Installs what the dashboard needs to drive bay: the binaries and the repo's
# bay config folder, into a Dokku persistent mount.
#
# Run this ON THE DOKKU HOST, once, and again to update bay.
#
#   ./install-host.sh                 install or refresh
#   ./install-host.sh --check         report, change nothing
#
# The mount survives a deploy; a slug does not, and 100 MB of binaries do not
# belong in one anyway.
set -euo pipefail

APP="${RQ_APP:-review-queue}"
HOST_ROOT="${RQ_BAY_HOST_ROOT:-/var/lib/dokku/data/storage/$APP/bay}"
CONTAINER_ROOT="${RQ_BAY_ROOT:-/app/rqbay}"
CHECK=false
[ "${1:-}" = "--check" ] && CHECK=true

ok()   { echo "  OK    $*"; }
todo() { echo "  TODO  $*"; MISSING=$((MISSING+1)); }
MISSING=0

echo "== tooling on this host =="
for b in docker git; do
  command -v "$b" >/dev/null && ok "$b" || todo "install $b"
done
COMPOSE=$(find /usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins -name docker-compose 2>/dev/null | head -1)
[ -n "$COMPOSE" ] && ok "docker compose plugin at $COMPOSE" || todo "install the docker compose plugin"

echo "== the mount =="
if $CHECK; then
  [ -d "$HOST_ROOT" ] && ok "$HOST_ROOT exists" || todo "create $HOST_ROOT (run without --check)"
else
  sudo mkdir -p "$HOST_ROOT/bin" "$HOST_ROOT/users"
  # The app runs as a non-root user inside the container, and it writes per-user
  # state here, so it must own the tree.
  sudo chown -R 32767:32767 "$HOST_ROOT" 2>/dev/null || sudo chmod -R 0777 "$HOST_ROOT"
  ok "$HOST_ROOT ready"
fi

echo "== bay + docker, into the mount =="
if $CHECK; then
  [ -x "$HOST_ROOT/bin/bay" ] && ok "bay installed" || todo "install bay (run without --check)"
elif [ -n "${RQ_BAY_SRC:-}" ] && [ -d "$RQ_BAY_SRC" ]; then
  (cd "$RQ_BAY_SRC" && GOFLAGS=-mod=vendor go build -o /tmp/bay .) \
    && sudo cp /tmp/bay "$HOST_ROOT/bin/bay" && rm -f /tmp/bay && ok "bay built from $RQ_BAY_SRC"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  # bay is private, so `go install` cannot fetch it. Clone with the token and
  # build from the vendored dependencies, which needs no further network.
  command -v go >/dev/null || {
    GO_VER=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
    curl -fsSL "https://go.dev/dl/${GO_VER}.linux-$(dpkg --print-architecture).tar.gz" -o /tmp/go.tgz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    export PATH=/usr/local/go/bin:$PATH
  }
  export PATH=/usr/local/go/bin:$PATH
  rm -rf /tmp/bay-src
  git clone --quiet --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/ubicloud/bay.git" /tmp/bay-src
  (cd /tmp/bay-src && GOFLAGS=-mod=vendor go build -o /tmp/bay .)
  sudo cp /tmp/bay "$HOST_ROOT/bin/bay"; rm -rf /tmp/bay-src /tmp/bay
  ok "bay built from main"
else
  todo "set GITHUB_TOKEN (bay is a private repo) or RQ_BAY_SRC"
fi

if ! $CHECK; then
  sudo cp "$(command -v docker)" "$HOST_ROOT/bin/docker"
  sudo mkdir -p "$HOST_ROOT/bin/cli-plugins"
  [ -n "$COMPOSE" ] && sudo cp "$COMPOSE" "$HOST_ROOT/bin/cli-plugins/docker-compose"
  sudo chmod 0755 "$HOST_ROOT"/bin/bay "$HOST_ROOT"/bin/docker "$HOST_ROOT"/bin/cli-plugins/* 2>/dev/null || true
  ok "docker CLI + compose staged"
fi

echo "== the repo's bay config =="
CFG_URL="${RQ_BAY_CONFIG_REPO:-git@github.com:ubicloud/bay-ubicloud.git}"
if $CHECK; then
  [ -f "$HOST_ROOT/config/bay.toml" ] && ok "config folder present" || todo "clone $CFG_URL into $HOST_ROOT/config"
elif [ -d "$HOST_ROOT/config/.git" ]; then
  sudo git -C "$HOST_ROOT/config" pull --quiet --ff-only && ok "config folder updated"
else
  sudo git clone --quiet "$CFG_URL" "$HOST_ROOT/config" && ok "config folder cloned" \
    || todo "clone it by hand: git clone $CFG_URL $HOST_ROOT/config"
fi

echo "== the dokku mount =="
if dokku storage:list "$APP" 2>/dev/null | grep -q "$CONTAINER_ROOT"; then
  ok "mounted at $CONTAINER_ROOT"
elif $CHECK; then
  todo "dokku storage:mount $APP $HOST_ROOT:$CONTAINER_ROOT"
else
  dokku storage:mount "$APP" "$HOST_ROOT:$CONTAINER_ROOT" && ok "mounted (restart the app to pick it up)"
fi

echo
if [ "$MISSING" -eq 0 ]; then
  echo "Ready. The dashboard can drive bay."
else
  echo "$MISSING thing(s) still to do."
  exit 1
fi
