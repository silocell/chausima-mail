#!/usr/bin/env bash
# Chausima Search: YaCy crawls hard at night and gently in the day, automatically.
#   night (20:00-06:00 UK time): 600 pages a minute, up to 0.85 of the core
#   day   (06:00-20:00 UK time): 120 pages a minute, up to 0.5 of the core
#   always lowest CPU priority, so the Launchpad, AI and mail go first whenever they need the processor.
# Installs /usr/local/bin/yacy-mode and two systemd timers. Safe to re-run.
set -e
sudo tee /usr/local/bin/yacy-mode >/dev/null <<'MODE'
#!/usr/bin/env bash
# usage: yacy-mode day|night|auto
m="$1"; [ "$m" = auto ] || [ -z "$m" ] && { h=$(TZ=Europe/London date +%H); if [ "$h" -ge 20 ] || [ "$h" -lt 6 ]; then m=night; else m=day; fi; }
PW=$(sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
if [ "$m" = night ]; then CPUS=0.85; PPM=600; else CPUS=0.5; PPM=120; fi
docker update --cpu-shares 128 --cpus $CPUS yacy >/dev/null
c=$(curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" -G http://127.0.0.1:8090/Crawler_p.html -d crawlingPerformance=custom -d customPPM=$PPM)
echo "$(date '+%F %H:%M') yacy-mode $m: cpus $CPUS, $PPM pages/min (http $c)" | tee -a /var/log/yacy-mode.log
MODE
sudo chmod 755 /usr/local/bin/yacy-mode
for m in day night; do
  sudo tee /etc/systemd/system/yacy-$m.service >/dev/null <<UNIT
[Unit]
Description=YaCy $m mode
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/yacy-mode $m
UNIT
done
sudo tee /etc/systemd/system/yacy-day.timer >/dev/null <<'T'
[Unit]
Description=YaCy gentle from 6am (UK)
[Timer]
OnCalendar=*-*-* 06:00:00 Europe/London
Persistent=true
[Install]
WantedBy=timers.target
T
sudo tee /etc/systemd/system/yacy-night.timer >/dev/null <<'T'
[Unit]
Description=YaCy full speed from 8pm (UK)
[Timer]
OnCalendar=*-*-* 20:00:00 Europe/London
Persistent=true
[Install]
WantedBy=timers.target
T
sudo systemctl daemon-reload
sudo systemctl enable --now yacy-day.timer yacy-night.timer >/dev/null 2>&1
sudo /usr/local/bin/yacy-mode auto
systemctl list-timers 'yacy-*' --no-pager | head -4
sleep 15; uptime
echo "Launchpad answers in: $(curl -s -o /dev/null -w '%{time_total}s' https://hehs-live.duckdns.org/auth/v1/health)"
