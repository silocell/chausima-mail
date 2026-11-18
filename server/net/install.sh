#!/usr/bin/env bash
# Puts net.chausima.com live on HEH-Live (Caddy gets its certificate by itself once the DNS points here).
# Needs a GoDaddy DNS record first:  Type A,  Name net,  Value 140.238.91.12
# Run on the server:  bash server/net/install.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); CF=/etc/caddy/Caddyfile; D=/srv/hwl-net
sudo mkdir -p $D
sudo cp "$HERE/index.html" "$HERE/icon.png" $D/
sudo chmod 755 $D; sudo chmod a+r $D/*; sudo chcon -R -t httpd_sys_content_t $D 2>/dev/null || true   # let Caddy read it (SELinux)
sudo cp $CF $CF.before-net
if ! sudo grep -q '^net.chausima.com' $CF; then
  sudo tee -a $CF >/dev/null <<'C'

net.chausima.com {
	root * /srv/hwl-net
	header Cache-Control "no-cache"
	try_files {path} /index.html
	file_server
}
C
fi
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-net $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 5
echo "net.chausima.com -> $(curl -s -o /dev/null -w '%{http_code}' https://net.chausima.com/ || echo 'not yet (DNS or certificate still coming)')"
