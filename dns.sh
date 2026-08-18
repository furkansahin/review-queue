#!/usr/bin/env bash
# Create or update review.furkansahin.work -> VM IP in Cloudflare.
#
#   CF_API_TOKEN=... VM_IP=1.2.3.4 ./dns.sh
#
# Token needs Zone -> DNS -> Edit on the zone. Looking the zone up by name also
# needs Zone -> Zone -> Read; if your token lacks that, pass ZONE_ID=... directly
# (Cloudflare shows it on the zone's Overview page) and the lookup is skipped.
set -euo pipefail

: "${CF_API_TOKEN:?set CF_API_TOKEN}"
: "${VM_IP:?set VM_IP to the Ubicloud VM public IPv4}"
ZONE=${ZONE:-furkansahin.work}
NAME=${NAME:-review.furkansahin.work}
PROXIED=${PROXIED:-false}   # false while issuing the Let's Encrypt cert

api() { curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }

# Every Cloudflare response goes through cf(), which turns success=false into
# Cloudflare's own error text. Without this, an auth failure lands as a bare
# "TypeError: 'NoneType' object is not subscriptable" on the null result.
cf() { # cf <label> <python-expression-over-d>
  CF_RESP="$2" python3 - "$1" "$3" <<'PY'
import json, os, sys
label, expr = sys.argv[1], sys.argv[2]
raw = os.environ["CF_RESP"]
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(f"{label}: cloudflare returned non-JSON:\n{raw[:400]}")
if not d.get("success"):
    errs = "; ".join(
        f'{e.get("code", "?")}: {e.get("message", "?")}' for e in (d.get("errors") or [])
    )
    sys.exit(f"{label}: {errs or 'request failed with no error detail'}")
print(eval(expr, {"d": d}))
PY
}

if [ -n "${ZONE_ID:-}" ]; then
  zone_id=$ZONE_ID
  echo "zone $ZONE -> $zone_id (from ZONE_ID)"
else
  resp=$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE")
  zone_id=$(cf "zone lookup for '$ZONE'" "$resp" \
    "(d['result'] or [{}])[0].get('id') or sys.exit('no zone named that is visible to this token')")
  echo "zone $ZONE -> $zone_id"
fi

resp=$(api "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$NAME")
rec_id=$(cf "record lookup for '$NAME'" "$resp" "d['result'][0]['id'] if d['result'] else ''")

body=$(printf '{"type":"A","name":"%s","content":"%s","ttl":300,"proxied":%s}' "$NAME" "$VM_IP" "$PROXIED")

if [ -n "$rec_id" ]; then
  echo "updating existing record $rec_id"
  resp=$(api -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" -d "$body")
  cf "update $NAME" "$resp" "'ok -> ' + d['result']['content']"
else
  echo "creating record"
  resp=$(api -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" -d "$body")
  cf "create $NAME" "$resp" "'ok -> ' + d['result']['content']"
fi

echo "verify:  dig +short $NAME"
