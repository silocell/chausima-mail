#!/bin/bash
# Sets up the info@ complaint log on HEH-Live. Run with sudo:
#   sudo bash install.sh hwlsystemslogs@aol.com
# Asks once for info@chausima.com's password (shown while you type, wiped
# after Enter) and uses it for both:
#   - the info@ logger (copies to the log mailbox, deletes after 3.5 min)
#   - the Launchpad help desk, which now reads info@ from Chausima Mail
#     instead of Mailbux
# Also creates the mail_log table and the maillog function behind
# Maintenance -> Mail log. Nothing secret is printed.
set -e
LOG_TO=${1:?log address}
HERE=$(cd "$(dirname "$0")" && pwd)
SB=/home/opc/supabase

install -m 755 "$HERE/info-logger.py" /usr/local/sbin/chausima-info-logger

PW=""
if [ ! -s /etc/chausima-logger.env ] || [ "$2" = newpass ]; then
  echo "Type or paste info@chausima.com's password. You'll see it while typing;"
  echo "it disappears from the screen as soon as you press Enter."
  read -rp "Password: " PW
  printf '\033[1A\033[2K\r'; clear; printf '\033[3J'; echo "Password saved (hidden)."
  [ -n "$PW" ] || { echo "No password given."; exit 1; }
  ( umask 077; printf 'INFO_USER=info@chausima.com\nINFO_PASS=%s\nLOG_TO=%s\n' "$PW" "$LOG_TO" > /etc/chausima-logger.env )
else
  PW=$(grep '^INFO_PASS=' /etc/chausima-logger.env | cut -d= -f2-)
fi
chmod 600 /etc/chausima-logger.env; chown root:root /etc/chausima-logger.env

echo "1/4 help desk -> Chausima Mail"
cp -p $SB/.env $SB/.env.bak-helpdesk-$(date +%Y%m%d%H%M)
HD_PW="$PW" python3 - "$SB/.env" <<'PY'
import os, sys
p = sys.argv[1]; lines = open(p).read().split("\n")
want = {"HELPDESK_JMAP_URL": "https://mail.chausima.com/jmap/session", "HELPDESK_JMAP_USER": "info@chausima.com", "HELPDESK_JMAP_PASS": os.environ["HD_PW"]}
out, done = [], set()
for l in lines:
    k = l.split("=", 1)[0]
    if k in want:
        if k in done: continue          # drop duplicate lines
        out.append(f"{k}={want[k]}"); done.add(k)
    else: out.append(l)
for k, v in want.items():
    if k not in done: out.insert(len(out) - 1 if out and out[-1] == "" else len(out), f"{k}={v}")
open(p, "w").write("\n".join(out))
print("   .env updated (old copy kept as .env.bak-helpdesk-*)")
PY
unset PW

echo "2/4 mail_log table"
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -t < "$HERE/mail_log.sql" | sed 's/^/   /'

echo "3/4 maillog function + restart functions"
mkdir -p $SB/volumes/functions/maillog
install -m 644 "$HERE/maillog/index.ts" $SB/volumes/functions/maillog/index.ts
chown -R opc:opc $SB/volumes/functions/maillog
chcon -R --reference=$SB/volumes/functions/helpdesk $SB/volumes/functions/maillog 2>/dev/null || true
SVC=$(docker inspect supabase-edge-functions --format '{{index .Config.Labels "com.docker.compose.service"}}')
( cd $SB && docker compose up -d --force-recreate --no-deps "$SVC" 2>&1 | tail -2 | sed 's/^/   /' )
sleep 8; echo "   functions: $(docker inspect -f '{{.State.Status}}' supabase-edge-functions)"

echo "4/4 logger service"
mkdir -p /var/lib/chausima-logger
cat > /etc/systemd/system/chausima-info-logger.service <<'U'
[Unit]
Description=Chausima Mail info@ complaint log (copies to log address, then deletes after 3.5 min)
After=network-online.target docker.service
[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/chausima-info-logger
Restart=always
RestartSec=20
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload; systemctl enable chausima-info-logger >/dev/null 2>&1; systemctl restart chausima-info-logger
sleep 6; journalctl -u chausima-info-logger -n 6 --no-pager -o cat | sed 's/^/   /'
echo "Done. Send a test email to info@chausima.com."
