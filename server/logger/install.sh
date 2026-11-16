#!/bin/bash
# Installs the info@ complaint logger. Run on the server with sudo.
#   sudo bash install.sh hwlsystemslogs@aol.com
# You'll be asked for info@'s app password; nothing you type is shown or printed.
set -e
LOG_TO=${1:?log address}
install -m 755 "$(dirname "$0")/info-logger.py" /usr/local/sbin/chausima-info-logger
if [ ! -s /etc/chausima-logger.env ] || [ "$2" = newpass ]; then
  echo "Type or paste info@chausima.com's password. You'll see it while typing;"
  echo "it disappears from the screen as soon as you press Enter."
  read -rp "Password: " PW
  printf '\033[1A\033[2K\r'; clear; printf '\033[3J'; echo "Password saved (hidden)."
  [ -n "$PW" ] || { echo "No password given."; exit 1; }
  umask 077; printf 'INFO_USER=info@chausima.com\nINFO_PASS=%s\nLOG_TO=%s\n' "$PW" "$LOG_TO" > /etc/chausima-logger.env; unset PW
fi
chmod 600 /etc/chausima-logger.env; chown root:root /etc/chausima-logger.env
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
systemctl daemon-reload; systemctl enable --now chausima-info-logger >/dev/null 2>&1; systemctl restart chausima-info-logger
sleep 4; journalctl -u chausima-info-logger -n 5 --no-pager -o cat
