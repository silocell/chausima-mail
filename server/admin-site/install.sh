#!/usr/bin/env bash
# admin.chausima.com = HWL Admin. The page itself stays in the HEH-Maintenance repo (maintenance.civilinitiatives.org/hwl/);
# Caddy shows it at admin.chausima.com, so pushing to GitHub updates it as usual.
# Also lets "Sign in with Google" come back to admin.chausima.com, and lets the HWL Admin agent answer this address.
# Needs DNS:  A  admin  140.238.91.12.   Run:  sudo bash install.sh   (safe to re-run; never touches the firewall)
set -e
HERE=$(cd "$(dirname "$0")" && pwd); CF=/etc/caddy/Caddyfile; ENVF=/home/opc/supabase/.env
echo "== HWL Admin agent (knows the new address)"
bash "$HERE/../hwl-admin/install.sh" | tail -2
echo "== Caddy"
cp $CF $CF.before-admin
if ! grep -q '^admin.chausima.com' $CF; then
  cat >> $CF <<'C'

admin.chausima.com {
	rewrite * /hwl{uri}
	reverse_proxy https://maintenance.civilinitiatives.org {
		header_up Host maintenance.civilinitiatives.org
	}
}
C
fi
if caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then echo "Caddy reloaded"
else cp $CF.before-admin $CF; systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
echo "== sign-in return address"
if grep -q '^ADDITIONAL_REDIRECT_URLS=' $ENVF && ! grep -q 'admin.chausima.com' $ENVF; then
  cp $ENVF $ENVF.bak-admin-$(date +%Y%m%d%H%M)
  sed -i 's#^\(ADDITIONAL_REDIRECT_URLS=.*[^,]\)$#\1,https://admin.chausima.com/**#' $ENVF
  ( cd /home/opc/supabase && docker compose up -d --no-deps auth >/dev/null 2>&1 ) && echo "auth restarted with admin.chausima.com allowed"
else echo "already allowed (or no list to add to)"; fi
sleep 8
echo "admin.chausima.com -> $(curl -s -o /dev/null -w '%{http_code}' https://admin.chausima.com/ || echo 'not yet (DNS or certificate still coming)')"
