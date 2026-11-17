#!/usr/bin/env bash
# Chausima Search: YaCy crawls hard at night and gently in the day, automatically.
#   night (20:00-06:00 UK time) is maintenance time: YaCy gets TOP priority and nearly all the cores
#        (every core but 0.1), 1000 pages a minute
#   day   (06:00-20:00 UK time): YaCy gets LOWEST priority and a third of the cores (at least half a core),
#        120 pages a minute, so the Launchpad, AI and mail always go first
#   Limits follow the number of cores, so a bigger server (e.g. 3 cores) is used automatically.
# Installs /usr/local/bin/yacy-mode and two systemd timers. Safe to re-run.
set -e
sudo tee /usr/local/bin/yacy-mode >/dev/null <<'MODE'
#!/usr/bin/env bash
# usage: yacy-mode day|night|auto
m="$1"; [ "$m" = auto ] || [ -z "$m" ] && { h=$(TZ=Europe/London date +%H); if [ "$h" -ge 20 ] || [ "$h" -lt 6 ]; then m=night; else m=day; fi; }
PW=$(sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
N=$(nproc)
if [ "$m" = night ]; then CPUS=$(awk -v n=$N 'BEGIN{printf "%.2f", n-0.1}'); SHARES=4096; PPM=1000
else CPUS=$(awk -v n=$N 'BEGIN{c=n/3; if(c<0.5)c=0.5; printf "%.2f", c}'); SHARES=128; PPM=120; fi
docker update --cpu-shares $SHARES --cpus $CPUS yacy >/dev/null
c=$(curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" -G http://127.0.0.1:8090/Crawler_p.html -d crawlingPerformance=custom -d customPPM=$PPM)
echo "$(date '+%F %H:%M') yacy-mode $m: $N cores, yacy gets $CPUS (priority $SHARES), $PPM pages/min (http $c)" | tee -a /var/log/yacy-mode.log
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
Description=YaCy full power and priority from 8pm (UK, maintenance time)
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
