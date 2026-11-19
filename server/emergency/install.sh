#!/usr/bin/env bash
# Installs the HEH-Live emergency page (command runner + AI helper). Safe to re-run.
#  - /usr/local/lib/hwl-emergency/{emergency.py,page.html,guide.md}, service hwl-emergency on 127.0.0.1:8712
#  - its own service: lockdown, HWL Admin restarts and hwl-recover never touch it; it restarts once a day (04:45)
#    and starts at boot
#  - Caddy: https://hehs-live.duckdns.org/hwl-emergency/* -> it (anything but the secret address says "Nothing here")
#  - /var/log/hwl-emergency.log append-only
# Switched on only once you make its secret address:  sudo hwl-admin-pin --runner
set -e
HERE=$(cd "$(dirname "$0")" && pwd); CF=/etc/caddy/Caddyfile; L=/usr/local/lib/hwl-emergency
sudo install -d -m 700 $L
sudo install -m 700 "$HERE/emergency.py" $L/emergency.py
sudo install -m 600 "$HERE/page.html" "$HERE/guide.md" $L/
sudo touch /var/log/hwl-emergency.log; sudo chmod 600 /var/log/hwl-emergency.log 2>/dev/null || true; sudo chattr +a /var/log/hwl-emergency.log 2>/dev/null || true
sudo tee /etc/systemd/system/hwl-emergency.service >/dev/null <<'U'
[Unit]
Description=HEH-Live emergency page (127.0.0.1:8712)
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/hwl-emergency/emergency.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U
sudo tee /etc/systemd/system/hwl-emergency-daily.service >/dev/null <<'U'
[Unit]
Description=Daily restart of the HEH-Live emergency page
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart hwl-emergency.service
U
sudo tee /etc/systemd/system/hwl-emergency-daily.timer >/dev/null <<'U'
[Unit]
Description=Restart the emergency page once a day
[Timer]
OnCalendar=*-*-* 04:45:00
Persistent=false
[Install]
WantedBy=timers.target
U
sudo systemctl daemon-reload
sudo systemctl enable --now hwl-emergency-daily.timer >/dev/null 2>&1
sudo systemctl enable hwl-emergency.service >/dev/null 2>&1; sudo systemctl restart hwl-emergency.service
sudo cp $CF $CF.before-hwl-emergency
if ! sudo grep -q 'hwl-emergency-route' $CF; then
  sudo python3 - "$CF" <<'P'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'(?m)^hehs-live\.duckdns\.org[^\n{]*\{\n', s)
assert m, "hehs-live site block not found"
add='\t# hwl-emergency-route\n\thandle /hwl-emergency/* {\n\t\treverse_proxy 127.0.0.1:8712\n\t}\n'
s=s[:m.end()]+add+s[m.end():]; open(p,'w').write(s); print("Caddy: /hwl-emergency route added")
P
fi
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-hwl-emergency $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 2
echo "emergency page: $(systemctl is-active hwl-emergency)  (daily restart: $(systemctl is-enabled hwl-emergency-daily.timer))"
echo "a wrong address -> $(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/hwl-emergency/nope) (should be 404)"
[ -s /etc/hwl-admin/runner-path ] && echo "secret address is set (see it with: sudo hwl-admin-pin --runner-show)" || echo "now make its secret address: sudo hwl-admin-pin --runner"
