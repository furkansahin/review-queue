#!/usr/bin/env bash
# Run ON the Dokku host, once. Edit the values first.
set -euo pipefail

APP=review-queue
DOMAIN=queue.example.com
GITHUB_TOKEN=github_pat_xxx
RQ_PASSWORD=$(openssl rand -base64 24)

dokku apps:create "$APP"
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
dokku ps:scale "$APP" web=1

echo "basic auth password: $RQ_PASSWORD"
echo "now push:  git remote add dokku dokku@<host>:$APP && git push dokku main"
echo "then TLS:  dokku letsencrypt:set $APP email you@example.com && dokku letsencrypt:enable $APP"
