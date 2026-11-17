#!/usr/bin/env bash
# Installs the linkcheck function (AI safety check for pages opened in HWL OS's Browser). Safe to re-run.
set -e
SB=/home/opc/supabase; HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p $SB/volumes/functions/linkcheck
install -m 644 "$HERE/linkcheck/index.ts" $SB/volumes/functions/linkcheck/index.ts
chown -R opc:opc $SB/volumes/functions/linkcheck
chcon -R --reference=$SB/volumes/functions/helpdesk $SB/volumes/functions/linkcheck 2>/dev/null || true
SVC=$(docker inspect supabase-edge-functions --format '{{index .Config.Labels "com.docker.compose.service"}}')
( cd $SB && docker compose up -d --force-recreate --no-deps "$SVC" 2>&1 | tail -2 )
sleep 10; echo "functions: $(docker inspect -f '{{.State.Status}}' supabase-edge-functions)"
ANON=$(grep '^ANON_KEY=' $SB/.env | cut -d= -f2-)
echo "no sign-in -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'content-type: application/json' -d '{"url":"https://example.com"}' https://hehs-live.duckdns.org/functions/v1/linkcheck) (should be 401)"
echo "helpdesk still -> $(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/functions/v1/helpdesk)"
