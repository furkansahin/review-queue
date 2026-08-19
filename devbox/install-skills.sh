#!/usr/bin/env bash
# Install a personal Claude Code skills repo into a bay box.
#
# The box's ~/.claude is a fresh volume, and bay seeds only CLAUDE.md into it,
# so skills have to be installed per box as a setup step.
#
# Driven by an env var so bay.toml can stay shared: bay.toml names this script,
# each developer names their own repo. Nobody inherits anyone else's skills.
#
#   ~/.bay/env      CLAUDE_SKILLS_REPO=furkansahin/skills
#                   GITHUB_TOKEN=...        (needs Contents: Read on that repo)
#
# Unset CLAUDE_SKILLS_REPO and this is a no-op.
set -euo pipefail

REPO="${CLAUDE_SKILLS_REPO:-}"
DEST="${CLAUDE_SKILLS_DEST:-$HOME/.claude/skills}"
REF="${CLAUDE_SKILLS_REF:-}"

if [ -z "$REPO" ]; then
  echo "skills: CLAUDE_SKILLS_REPO not set, skipping"
  exit 0
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "skills: GITHUB_TOKEN not set; cannot clone $REPO" >&2
  exit 0     # a missing personal extra must not fail the whole box
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# x-access-token keeps the token out of the URL's user field in git's config.
url="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
if [ -n "$REF" ]; then
  git clone --quiet --depth 1 --branch "$REF" "$url" "$tmp/repo"
else
  git clone --quiet --depth 1 "$url" "$tmp/repo"
fi
# Do not leave the token behind in the clone's remote.
git -C "$tmp/repo" remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null || true

mkdir -p "$DEST"

# A skill is any directory holding a SKILL.md. Find them wherever they sit, so
# this works whether the repo puts them at the root or under skills/.
count=0
while IFS= read -r skillmd; do
  dir=$(dirname "$skillmd")
  name=$(basename "$dir")
  rm -rf "${DEST:?}/$name"
  cp -r "$dir" "$DEST/$name"
  count=$((count + 1))
done < <(find "$tmp/repo" -name SKILL.md -not -path "*/.git/*" -print)

if [ "$count" -eq 0 ]; then
  echo "skills: no SKILL.md found in $REPO — nothing installed" >&2
  exit 0
fi

echo "skills: installed $count from $REPO into $DEST"
ls -1 "$DEST" | sed 's/^/  /'
