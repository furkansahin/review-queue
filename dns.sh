#!/usr/bin/env bash
# Create or update review.furkansahin.work -> VM IP in Cloudflare.
#
#   CF_API_TOKEN=... VM_IP=1.2.3.4 ./dns.sh
#
# Token needs: Zone -> DNS -> Edit on the furkansahin.work zone.
set -euo pipefail

: "${CF_API_TOKEN:?set CF_API_TOKEN}"
: "${VM_IP:?set VM_IP to the Ubicloud VM public IPv4}"
ZONE=${ZONE:-furkansahin.work}
NAME=${NAME:-review.furkansahin.work}
PROXIED=${PROXIED:-false}   # false while issuing the Let's Encrypt cert

api() { curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
jqr() { python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

zone_id=$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE" | jqr "['result'][0]['id']")
echo "zone $ZONE -> $zone_id"

rec_id=$(api "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$NAME" \
  | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r[0]['id'] if r else '')")

body=$(printf '{"type":"A","name":"%s","content":"%s","ttl":300,"proxied":%s}' "$NAME" "$VM_IP" "$PROXIED")

if [ -n "$rec_id" ]; then
  echo "updating existing record $rec_id"
  api -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" -d "$body" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print('ok' if d['success'] else d['errors'])"
else
  echo "creating record"
  api -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" -d "$body" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print('ok' if d['success'] else d['errors'])"
fi

echo "verify:  dig +short $NAME"
