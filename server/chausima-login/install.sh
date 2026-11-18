#!/usr/bin/env bash
# Installs the chausima-login function (Sign in with Chausima). Safe to re-run.
set -e
SB=/home/opc/supabase; HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p $SB/volumes/functions/chausima-login
install -m 644 "$HERE/chausima-login/index.ts" $SB/volumes/functions/chausima-login/index.ts
chown -R opc:opc $SB/volumes/functions/chausima-login
chcon -R --reference=$SB/volumes/functions/helpdesk $SB/volumes/functions/chausima-login 2>/dev/null || true
SVC=$(docker inspect supabase-edge-functions --format '{{index .Config.Labels "com.docker.compose.service"}}')
( cd $SB && docker compose up -d --force-recreate --no-deps "$SVC" 2>&1 | tail -2 )
sleep 10; echo "functions: $(docker inspect -f '{{.State.Status}}' supabase-edge-functions)"
ANON=$(grep '^ANON_KEY=' $SB/.env | cut -d= -f2-)
echo "no sign-in -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'content-type: application/json' -d '{"email":"nobody","password":"x"}' https://hehs-live.duckdns.org/functions/v1/chausima-login) (should be 200 with a 'don't match' answer)"
echo "helpdesk still -> $(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/functions/v1/helpdesk)"
