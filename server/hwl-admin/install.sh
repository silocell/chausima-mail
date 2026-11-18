#!/usr/bin/env bash
# Installs the HWL Admin agent on HEH-Live. Safe to re-run.
#  - /usr/local/lib/hwl-admin/agent.py, run by systemd as hwl-admin.service on 127.0.0.1:8711 only
#  - Caddy: https://hehs-live.duckdns.org/hwl-admin/* -> the agent (nothing else changes)
#  - /var/log/hwl-admin.log made append-only (chattr +a): actions can be added, never edited or deleted
# Never touches the firewall.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); CF=/etc/caddy/Caddyfile
sudo install -D -m 700 "$HERE/agent.py" /usr/local/lib/hwl-admin/agent.py
sudo touch /var/log/hwl-admin.log; sudo chmod 600 /var/log/hwl-admin.log 2>/dev/null || true; sudo chattr +a /var/log/hwl-admin.log 2>/dev/null || true   # already append-only on a re-run: fine
sudo tee /etc/systemd/system/hwl-admin.service >/dev/null <<'U'
[Unit]
Description=HWL Admin agent (127.0.0.1:8711)
After=docker.service network-online.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/hwl-admin/agent.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U
sudo systemctl daemon-reload; sudo systemctl enable hwl-admin.service >/dev/null 2>&1; sudo systemctl restart hwl-admin.service
sudo cp $CF $CF.before-hwl-admin
if ! sudo grep -q 'hwl-admin-route' $CF; then
  sudo python3 - "$CF" <<'P'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'(?m)^hehs-live\.duckdns\.org[^\n{]*\{\n', s)
assert m, "hehs-live site block not found"
add='\t# hwl-admin-route\n\thandle /hwl-admin/* {\n\t\treverse_proxy 127.0.0.1:8711\n\t}\n'
s=s[:m.end()]+add+s[m.end():]; open(p,'w').write(s); print("Caddy: /hwl-admin route added")
P
fi
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-hwl-admin $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 3
echo "agent: $(systemctl is-active hwl-admin)"
echo "no sign-in -> $(curl -s -o /dev/null -w '%{http_code}' -X POST https://hehs-live.duckdns.org/hwl-admin/api -d '{}') (should be 403)"
