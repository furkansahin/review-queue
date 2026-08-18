#!/usr/bin/env bash
# Run ON the Dokku host. Safe to re-run: creates what's missing, leaves the rest alone.
# Edit APP/DOMAIN/GITHUB_TOKEN first.
set -euo pipefail

APP=review-queue
DOMAIN=review.furkansahin.work
GITHUB_TOKEN=github_pat_xxx

if [ "$GITHUB_TOKEN" = "github_pat_xxx" ]; then
  echo "edit GITHUB_TOKEN in this script first" >&2
  exit 1
fi

if dokku apps:exists "$APP" >/dev/null 2>&1; then
  echo "app $APP already exists, reusing it"
else
  dokku apps:create "$APP"
fi

# Keep the password from a previous run; only mint one if there isn't one yet.
RQ_PASSWORD=$(dokku config:get "$APP" RQ_PASSWORD 2>/dev/null || true)
if [ -z "$RQ_PASSWORD" ]; then
  RQ_PASSWORD=$(openssl rand -base64 24)
  echo "generated a new basic auth password"
else
  echo "keeping the existing basic auth password"
fi

dokku config:set --no-restart "$APP" \
  GITHUB_TOKEN="$GITHUB_TOKEN" \
  RQ_USER=me \
  RQ_PASSWORD="$RQ_PASSWORD" \
  RQ_SCOPE=repo:ubicloud/ubicloud \
  RQ_LABEL=clickhouse \
  RQ_WARN_DAYS=2 \
  RQ_HOT_DAYS=4 \
  RQ_STALE_DAYS=7 \
  RQ_CACHE_TTL=300 \
  RACK_ENV=production

dokku domains:set "$APP" "$DOMAIN"

echo
echo "basic auth password: $RQ_PASSWORD"
echo "now push:  git remote add dokku dokku@<host>:$APP && git push dokku main"
echo "then TLS:  dokku letsencrypt:set $APP email you@example.com && dokku letsencrypt:enable $APP"
