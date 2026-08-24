#!/usr/bin/env bash
# Prepares a baybox: docker, the docker group, and a checkout.
#
#   ./setup.sh           install what is missing
#   ./setup.sh --check   report only, change nothing
#
# This is the same work the dashboard's "Prepare this box" button does, and
# that button is the easier way -- it needs nothing on the box but the key from
# the Baybox page. This script exists for a machine you are already sitting on,
# or for one the dashboard cannot reach yet.
#
# A box needs three things and no more:
#   1. the dashboard's key in ~/.ssh/authorized_keys  (only you can add this)
#   2. docker, with this user able to use it
#   3. a checkout of the repository
#
# It used to install bay, a wrapper, a bay config and a token file as well.
# None of that lives on a box any more: the dashboard runs bay itself and
# drives this machine's docker over ssh.
set -euo pipefail

# This changes a machine. It once ran on a laptop by accident and rewrote an
# ssh config, so it refuses anything that is not a Linux box unless told.
if [ "$(uname -s)" != "Linux" ] && [ "${RQ_FORCE_HOST:-}" != "1" ]; then
  echo "setup.sh changes this machine and is meant for a Linux baybox." >&2
  echo "Run it there, or set RQ_FORCE_HOST=1 if you are certain." >&2
  exit 1
fi

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

REPO_URL="${RQ_REPO_URL:-https://github.com/ubicloud/ubicloud.git}"
REPO_PATH="${RQ_REPO_PATH:-$HOME/ubicloud}"

MISSING=0
ok()   { echo "  OK    $*"; }
todo() { echo "  TODO  $*"; MISSING=$((MISSING + 1)); }
doing(){ echo "  ..    $*"; }
can_change() { ! $CHECK_ONLY; }

echo "== the dashboard's key =="
# The one step nothing here can do: it is what grants the access the rest of
# this would use. The line to paste is on the Baybox page.
if grep -q "review-queue:" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  ok "a review-queue key is installed"
else
  todo "paste the key line from the dashboard's Baybox page into ~/.ssh/authorized_keys"
fi

echo "== docker =="
if command -v docker >/dev/null 2>&1; then
  ok "docker installed ($(docker --version 2>/dev/null))"
elif ! can_change; then
  todo "install docker (run without --check)"
elif ! sudo -n true 2>/dev/null; then
  todo "docker needs installing, and that needs sudo without a password"
else
  doing "installing docker from its own repository"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
    "$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")" \
    "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "docker installed ($(docker --version 2>/dev/null))"
fi

# Installing docker is not enough. Without the group every docker command needs
# sudo, and the dashboard does not use sudo -- it fails with "Cannot connect to
# the Docker daemon", which reads like the daemon is down when it is not.
if id -nG | grep -qw docker; then
  ok "$(id -un) can reach docker"
elif ! can_change; then
  todo "add $(id -un) to the docker group (run without --check)"
elif sudo -n true 2>/dev/null; then
  sudo usermod -aG docker "$(id -un)"
  ok "added $(id -un) to the docker group (takes effect on the next login)"
else
  todo "add $(id -un) to the docker group: sudo usermod -aG docker $(id -un)"
fi

echo "== checkout =="
if [ -d "$REPO_PATH/.git" ]; then
  ok "checkout at $REPO_PATH"
elif ! can_change; then
  todo "clone $REPO_URL into $REPO_PATH (run without --check)"
else
  doing "cloning $REPO_URL"
  # https, not ssh: the repository is public, so this needs no key on the box.
  git clone --quiet "$REPO_URL" "$REPO_PATH" && ok "cloned into $REPO_PATH" \
    || todo "clone failed: git clone $REPO_URL $REPO_PATH"
fi

echo "== capacity =="
# Measured: one box costs about 7G once its images and database are there.
avail=$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1048576)}')
if [ "${avail:-0}" -ge 20 ]; then
  ok "${avail}G free (about $((avail / 7)) boxes)"
else
  todo "only ${avail}G free; a box needs about 7G"
fi

echo
if [ "$MISSING" -eq 0 ]; then
  echo "Ready. Press Review on a pull request."
  exit 0
fi
echo "$MISSING thing(s) still to do."
exit 1
