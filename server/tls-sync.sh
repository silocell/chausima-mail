#!/bin/bash
# Copies Caddy's Let's Encrypt certificate for mail.chausima.com into Stalwart,
# so IMAP/POP3/SMTP use the same trusted certificate as the website.
# Installs itself as a daily timer the first time it runs with "install".
set -e
SRC=$(ls -d /var/lib/caddy/.local/share/caddy/certificates/*/mail.chausima.com 2>/dev/null | head -1)
DST=/mnt/launchpad-data/stalwart/etc/tls
[ -n "$SRC" ] || { echo "Caddy certificate for mail.chausima.com not found"; exit 1; }
mkdir -p $DST
changed=0
for f in crt key; do
  if ! cmp -s "$SRC/mail.chausima.com.$f" "$DST/mail.chausima.com.$f"; then cp "$SRC/mail.chausima.com.$f" "$DST/mail.chausima.com.$f"; changed=1; fi
done
chown -R 2000:2000 $DST; chmod 600 $DST/*.key; chcon -R -t container_file_t $DST 2>/dev/null || true
echo "cert: $(openssl x509 -in $DST/mail.chausima.com.crt -noout -enddate)"
if [ "$1" = install ]; then
  cp "$0" /usr/local/sbin/chausima-tls-sync 2>/dev/null || curl -sL https://raw.githubusercontent.com/silocell/chausima-mail/main/server/tls-sync.sh -o /usr/local/sbin/chausima-tls-sync
  chmod +x /usr/local/sbin/chausima-tls-sync
  printf '[Unit]\nDescription=Copy Caddy cert to Stalwart\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/chausima-tls-sync\n' > /etc/systemd/system/chausima-tls-sync.service
  printf '[Unit]\nDescription=Daily cert copy for Stalwart\n[Timer]\nOnCalendar=daily\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/chausima-tls-sync.timer
  systemctl daemon-reload; systemctl enable --now chausima-tls-sync.timer >/dev/null 2>&1; echo "daily timer on"
elif [ $changed = 1 ]; then docker restart stalwart >/dev/null && echo "certificate changed - Stalwart restarted"; fi
echo "in container: /opt/stalwart/etc/tls/mail.chausima.com.crt and .key"
