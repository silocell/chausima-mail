#!/usr/bin/env bash
# Lets the Launchpad AI look at pictures. Patches the live hwchat function, restarts the functions, and checks
# hwchat still answers; if it doesn't, the backup goes straight back. Run: sudo bash install.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); F=/home/opc/supabase/volumes/functions/hwchat/index.ts
python3 "$HERE/patch.py" "$F"
cd /home/opc/supabase
restart() { docker compose up -d --force-recreate --no-deps functions >/dev/null 2>&1 || docker restart supabase-edge-functions >/dev/null; sleep 12; }
restart
code=$(curl -s -o /tmp/hwchat.out -w '%{http_code}' -X POST https://hehs-live.duckdns.org/functions/v1/hwchat -H 'content-type: application/json' -d '{"action":"models"}')
if [ "$code" = 200 ] || [ "$code" = 401 ]; then echo "hwchat answers ($code) - pictures are on"
else
  echo "hwchat didn't answer properly ($code) - putting the backup back"; head -c 300 /tmp/hwchat.out; echo
  [ -f "$F.before-pictures" ] && cp "$F.before-pictures" "$F" && restart && echo "backup restored"
  exit 1
fi
