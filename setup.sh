#!/usr/bin/env bash
# Run ON the Dokku host. Safe to re-run: creates what's missing, leaves the rest alone.
# Edit APP/DOMAIN/allowlist and the OAuth credentials first.
set -euo pipefail

APP=review-queue
DOMAIN=review.furkansahin.work
BASE_URL="https://$DOMAIN"

# From the GitHub OAuth App (Settings -> Developer settings -> OAuth Apps).
# Authorization callback URL must be exactly $BASE_URL/auth/callback
GITHUB_CLIENT_ID=Ov23xxxxxxxxxxxx
GITHUB_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Only these GitHub logins may sign in. Comma separated, case-insensitive.
ALLOWED_LOGINS=furkansahin

if [ "$GITHUB_CLIENT_ID" = "Ov23xxxxxxxxxxxx" ]; then
  echo "edit GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET in this script first" >&2
  exit 1
fi

if dokku apps:exists "$APP" >/dev/null 2>&1; then
  echo "app $APP already exists, reusing it"
else
  dokku apps:create "$APP"
fi

# Rotating this signs everyone out, so only mint one when there isn't one yet.
SESSION_SECRET=$(dokku config:get "$APP" RQ_SESSION_SECRET 2>/dev/null || true)
if [ -z "$SESSION_SECRET" ]; then
  SESSION_SECRET=$(openssl rand -hex 32)   # 64 chars; the Roda sessions plugin requires >= 64
  echo "generated a new session secret"
else
  echo "keeping the existing session secret"
fi

dokku config:set --no-restart "$APP" \
  RQ_GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
  RQ_GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
  RQ_SESSION_SECRET="$SESSION_SECRET" \
  RQ_ALLOWED_LOGINS="$ALLOWED_LOGINS" \
  RQ_BASE_URL="$BASE_URL" \
  RQ_SCOPE=repo:ubicloud/ubicloud \
  RQ_LABEL=clickhouse \
  `# placeholder only; each user picks their own watch label` \
  RQ_WARN_DAYS=2 \
  RQ_HOT_DAYS=4 \
  RQ_STALE_DAYS=7 \
  RQ_CACHE_TTL=300 \
  RQ_QUICK_LINES=50 \
  RQ_LINES_PER_MIN=20 \
  RQ_IDLE_TTL=3600 \
  RQ_SNOOZE_DAYS=7 \
  RQ_MAX_USERS=25 \
  RACK_ENV=production

dokku domains:set "$APP" "$DOMAIN"

echo
echo "allowlist: $ALLOWED_LOGINS   (add more: dokku config:set $APP RQ_ALLOWED_LOGINS=a,b,c)"
echo "now push:  git remote add dokku dokku@<host>:$APP && git push dokku main"
echo "then TLS:  dokku letsencrypt:set $APP email you@example.com && dokku letsencrypt:enable $APP"
