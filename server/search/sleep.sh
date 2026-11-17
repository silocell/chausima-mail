#!/usr/bin/env bash
# Sleep mode for HEH-Live (UK time). Installs /usr/local/bin/hwl-sleep and three systemd timers. Safe to re-run.
#   23:00  sleep  - the websites show "asleep" (site.js does that by the clock); every service except YaCy is
#                   restarted one by one (fresh memory), then old logs are trimmed
#   03:00  deep   - every container except YaCy is stopped, and YaCy gets the whole server (all cores, 1500 pages/min).
#                   Caddy keeps running (it's tiny) so HWL Search still answers. Mail that arrives now waits at the
#                   sender and is delivered after 5:40 (mail servers retry for days).
#   05:40  wake   - everything that was stopped starts again and is checked; YaCy goes back to night mode,
#                   then yacy-day (6:00) makes it gentle for the day.
# Run by hand: sudo hwl-sleep sleep|deep|wake|status
set -e
sudo tee /usr/local/bin/hwl-sleep >/dev/null <<'S'
#!/usr/bin/env bash
LOG=/var/log/hwl-sleep.log; KEEP=/var/lib/hwl-sleep/stopped
mkdir -p /var/lib/hwl-sleep
say() { echo "$(date '+%F %H:%M:%S') $*" | tee -a $LOG; }
others() { docker ps --format '{{.Names}}' | grep -vx yacy; }
case "$1" in
  sleep)
    say "sleep: restarting services"
    for c in $(others); do docker restart -t 30 "$c" >/dev/null 2>&1 && say "  restarted $c" || say "  couldn't restart $c"; sleep 3; done
    journalctl --vacuum-time=21d >/dev/null 2>&1 || true
    say "sleep: done" ;;
  deep)
    others > $KEEP
    say "deep: stopping $(wc -l < $KEEP) containers, YaCy only"
    for c in $(tac $KEEP); do docker stop -t 30 "$c" >/dev/null 2>&1 && say "  stopped $c"; done
    N=$(nproc); PW=$(sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
    docker update --cpu-shares 8192 --cpus "$N" yacy >/dev/null
    curl -s -o /dev/null --digest -u "admin:$PW" -G http://127.0.0.1:8090/Crawler_p.html -d crawlingPerformance=custom -d customPPM=1500
    say "deep: YaCy has all $N cores, 1500 pages/min" ;;
  wake)
    say "wake: starting services"
    ( cd /home/opc/supabase 2>/dev/null && docker compose start >/dev/null 2>&1 && say "  Supabase started in order" ) || true
    if [ -s $KEEP ]; then for c in $(cat $KEEP); do docker start "$c" >/dev/null 2>&1 && say "  started $c" || say "  couldn't start $c"; done; fi
    # anything else that should be up (e.g. after a reboot) gets started too
    for c in $(docker ps -a --filter status=exited --format '{{.Names}}' | grep -vE '^(yacy|stalwart-prev)$'); do
      r=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c"); [ "$r" = no ] || { docker start "$c" >/dev/null 2>&1 && say "  started $c (was off)"; }
    done
    : > $KEEP
    /usr/local/bin/yacy-mode night >/dev/null 2>&1 || true
    for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/auth/v1/health); [ "$c" = 401 ] || [ "$c" = 200 ] && break; sleep 10; done
    say "wake: Launchpad answers ($c), mail $(docker inspect -f '{{.State.Status}}' stalwart 2>/dev/null)" ;;
  status)
    tail -15 $LOG; systemctl list-timers 'hwl-sleep-*' 'yacy-*' --no-pager ;;
  *) echo "usage: hwl-sleep sleep|deep|wake|status"; exit 1 ;;
esac
S
sudo chmod 755 /usr/local/bin/hwl-sleep
for m in sleep:23:00 deep:03:00 wake:05:40; do
  n=${m%%:*}; t=${m#*:}
  sudo tee /etc/systemd/system/hwl-sleep-$n.service >/dev/null <<U
[Unit]
Description=HEH-Live sleep mode: $n
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/hwl-sleep $n
TimeoutStartSec=30min
U
  sudo tee /etc/systemd/system/hwl-sleep-$n.timer >/dev/null <<U
[Unit]
Description=HEH-Live sleep mode: $n at $t (UK)
[Timer]
OnCalendar=*-*-* $t:00 Europe/London
[Install]
WantedBy=timers.target
U
done
# a server restart in the night must never leave things off: wake also runs at boot if it's after 05:40 or before 03:00
sudo tee /etc/systemd/system/hwl-sleep-boot.service >/dev/null <<'U'
[Unit]
Description=HEH-Live sleep mode: make sure everything is on after a restart (unless it's 3:00-5:40)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'h=$(TZ=Europe/London date +%%H%%M); [ "$h" -ge 0300 ] && [ "$h" -lt 0540 ] && exit 0; sleep 60; /usr/local/bin/hwl-sleep wake'
[Install]
WantedBy=multi-user.target
U
sudo systemctl daemon-reload
sudo systemctl enable --now hwl-sleep-sleep.timer hwl-sleep-deep.timer hwl-sleep-wake.timer >/dev/null 2>&1
sudo systemctl enable hwl-sleep-boot.service >/dev/null 2>&1
systemctl list-timers 'hwl-sleep-*' --no-pager | head -5
echo "Sleep mode installed: 23:00 restarts, 03:00 YaCy only, 05:40 wake. Check with: sudo hwl-sleep status"
