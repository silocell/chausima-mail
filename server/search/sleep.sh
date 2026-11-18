#!/usr/bin/env bash
# Sleep mode for HEH-Live (UK time). Installs /usr/local/bin/hwl-sleep, the school holidays list and systemd timers.
# Safe to re-run.
#
# School nights (Mon-Thu, not before a holiday):          Late nights (Fri, Sat, Sun, holidays and the night before one):
#   20:00-23:00  maintenance                                00:00-01:00  maintenance
#   23:00-03:00  sleep                                      01:00-03:00  sleep
#   03:00-05:40  deep sleep                                 03:00-05:40  deep sleep
#   05:40        wake (everything back by 6:00)             05:40        wake
#
#   maintenance - YaCy gets top priority and nearly all the cores; Chausima Mail runs slower (half a core)
#   sleep       - the websites that need the server show "asleep" (site.js and the mail page do that by the clock,
#                 with the same holiday list); every service except YaCy is restarted one by one (fresh memory),
#                 old logs are trimmed, then Chausima Mail goes to sleep: it keeps ACCEPTING incoming mail on
#                 port 25 and holds it (tiny power), but reading and sending (143, 993, 110, 995, 465, 587) close
#   deep sleep  - every container except YaCy and mail-receiving is stopped; YaCy gets the whole server,
#                 1500 pages/min. Caddy keeps running (tiny) so HWL Search still answers.
#   wake        - everything starts again and is checked, mail opens at full speed; yacy-day (6:00) makes YaCy gentle.
#
# One "tick" runs at each of those times and does whatever the time calls for, and at boot it puts things back
# the way they should be for that moment. Run by hand: sudo hwl-sleep tick|now|status (or wake/sleep/deep/...).
# Mail ports are closed with an iptables rule in Docker's DOCKER-USER chain (marked "hwl-sleep"), never firewall-cmd.
set -e
# Hatch End High School 2026-27 days off for students (INSET days and bank holidays included). Update each year.
sudo tee /etc/hwl-holidays >/dev/null <<'H'
2026-12-18 2027-01-03
2027-02-15 2027-02-19
2027-03-26 2027-04-11
2027-05-03 2027-05-03
2027-05-31 2027-06-04
2027-07-17 2027-08-31
H
sudo tee /usr/local/bin/hwl-sleep >/dev/null <<'S'
#!/usr/bin/env bash
export TZ=Europe/London
LOG=/var/log/hwl-sleep.log; KEEP=/var/lib/hwl-sleep/stopped; STATE=/var/lib/hwl-sleep/phase
mkdir -p /var/lib/hwl-sleep
say() { echo "$(date '+%F %H:%M:%S') $*" | tee -a $LOG; }
others() { docker ps --format '{{.Names}}' | grep -vxE 'yacy|stalwart'; }
MIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' stalwart 2>/dev/null)
RULE="-p tcp -m multiport --dports 143,993,110,995,465,587 -m comment --comment hwl-sleep -j REJECT --reject-with tcp-reset"
portsoff() { for ip in $MIP; do iptables -C DOCKER-USER -d $ip $RULE 2>/dev/null || iptables -I DOCKER-USER -d $ip $RULE; done; }
portson() { for i in 1 2 3 4 5 6; do l=$(iptables -S DOCKER-USER 2>/dev/null | grep hwl-sleep | head -1); [ -n "$l" ] || break
  eval "iptables ${l/-A /-D }"; done; }

holiday() { while read -r a b; do [ -n "$a" ] && [[ ! "$1" < "$a" ]] && [[ ! "$1" > "$b" ]] && return 0; done < /etc/hwl-holidays; return 1; }
late() { local w; w=$(date -d "$1" +%u); [ "$w" -ge 5 ] || holiday "$1" || holiday "$(date -d "$1 +1 day" +%F)"; }
phase() {   # what the time calls for right now: day | maint | sleep | deep
  local t D; t=$((10#$(date +%H%M))); if [ $t -ge 1200 ]; then D=$(date +%F); else D=$(date -d yesterday +%F); fi
  [ "$(cat /var/lib/hwl-sleep/skip 2>/dev/null)" = "$D" ] && { echo day; return; }   # HWL Admin: "skip tonight"
  if [ $t -ge 300 ] && [ $t -lt 540 ]; then echo deep; return; fi
  if late "$D"; then
    if [ $t -lt 100 ]; then echo maint; elif [ $t -lt 300 ]; then echo sleep; else echo day; fi
  else
    if [ $t -ge 2300 ] || [ $t -lt 300 ]; then echo sleep; elif [ $t -ge 2000 ]; then echo maint; else echo day; fi
  fi
}

mailslow() { docker update --cpu-shares 256 --cpus 0.5 stalwart >/dev/null 2>&1 && say "  Chausima Mail slower for maintenance (half a core)"; }
mailsleep() { docker update --cpu-shares 64 --cpus 0.3 stalwart >/dev/null 2>&1; portsoff
  say "  Chausima Mail asleep: still accepting incoming mail and holding it; reading and sending closed"; }
maint() { say "maintenance"; /usr/local/bin/yacy-mode night >/dev/null 2>&1 || true; mailslow; }
sleepnow() {
  say "sleep: restarting services"
  /usr/local/bin/yacy-mode night >/dev/null 2>&1 || true
  for c in $(others); do docker restart -t 30 "$c" >/dev/null 2>&1 && say "  restarted $c" || say "  couldn't restart $c"; sleep 3; done
  docker restart -t 60 stalwart >/dev/null 2>&1 && say "  restarted stalwart"
  journalctl --vacuum-time=21d >/dev/null 2>&1 || true
  sleep 20; mailsleep
  say "sleep: done"
}
deep() {
  others >> $KEEP
  say "deep: stopping $(others | wc -l) containers; YaCy at full power, mail only accepting"
  for c in $(others | tac); do docker stop -t 30 "$c" >/dev/null 2>&1 && say "  stopped $c"; done
  docker update --cpu-shares 64 --cpus 0.3 stalwart >/dev/null 2>&1; portsoff
  N=$(nproc); PW=$(sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
  docker update --cpu-shares 8192 --cpus "$N" yacy >/dev/null
  curl -s -o /dev/null --digest -u "admin:$PW" -G http://127.0.0.1:8090/Crawler_p.html -d crawlingPerformance=custom -d customPPM=1500
  say "deep: YaCy has all $N cores, 1500 pages/min"
}
wake() {
  say "wake: starting services"
  ( cd /home/opc/supabase 2>/dev/null && docker compose start >/dev/null 2>&1 && say "  Supabase started in order" ) || true
  if [ -s $KEEP ]; then for c in $(sort -u $KEEP); do docker start "$c" >/dev/null 2>&1 && say "  started $c" || say "  couldn't start $c"; done; fi
  for c in $(docker ps -a --filter status=exited --format '{{.Names}}' | grep -vE '^(yacy|stalwart-prev)$'); do   # anything else that should be up
    r=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c"); [ "$r" = no ] || { docker start "$c" >/dev/null 2>&1 && say "  started $c (was off)"; }
  done
  : > $KEEP
  portson; docker update --cpu-shares 1024 --cpus 0 stalwart >/dev/null 2>&1   # mail open, full speed
  if [ $((10#$(date +%H))) -lt 6 ]; then /usr/local/bin/yacy-mode night >/dev/null 2>&1; else /usr/local/bin/yacy-mode day >/dev/null 2>&1; fi
  for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/auth/v1/health); [ "$c" = 401 ] || [ "$c" = 200 ] && break; sleep 10; done
  say "wake: Launchpad answers ($c), mail $(docker inspect -f '{{.State.Status}}' stalwart 2>/dev/null)"
}
tick() {   # move to whatever the time calls for (only acts when that changes)
  local want was; want=$(phase); was=$(cat $STATE 2>/dev/null || echo day)
  [ "$want" = "$was" ] && [ "$1" != boot ] && return 0
  case "$want" in
    day)   wake ;;
    maint) [ "$1" = boot ] && wake; maint ;;
    sleep) if [ "$1" = boot ]; then wake; /usr/local/bin/yacy-mode night >/dev/null 2>&1; mailsleep; else sleepnow; fi ;;
    deep)  deep ;;
  esac
  echo "$want" > $STATE
}
# HWL Admin's master switch: while lockdown is on, leave everything stopped (only "status" and "now" work)
if grep -q '"lock": true' /var/lib/hwl-admin/state.json 2>/dev/null && [ "$1" != status ] && [ "$1" != now ]; then
  say "lockdown is on - not touching anything ($1)"; exit 0; fi
case "$1" in
  tick) tick ;;
  boot) sleep 60; tick boot ;;
  now)  echo "$(date '+%a %F %H:%M') - now: $(phase); last done: $(cat $STATE 2>/dev/null || echo day)" ;;
  mailslow|mailsleep|maint|deep|wake) "$1" ;;
  sleep) sleepnow ;;
  status) tail -15 $LOG; echo; "$0" now; systemctl list-timers 'hwl-sleep*' 'yacy-*' --no-pager ;;
  *) echo "usage: hwl-sleep tick|now|status|wake|sleep|deep|maint|mailslow|mailsleep"; exit 1 ;;
esac
S
sudo chmod 755 /usr/local/bin/hwl-sleep

# replace the earlier fixed-time timers with one tick at every change-over time
for n in mailslow sleep deep wake; do sudo systemctl disable --now hwl-sleep-$n.timer >/dev/null 2>&1 || true; sudo rm -f /etc/systemd/system/hwl-sleep-$n.timer /etc/systemd/system/hwl-sleep-$n.service; done
sudo systemctl disable --now yacy-night.timer >/dev/null 2>&1 || true   # maintenance now starts YaCy's night mode itself
sudo tee /etc/systemd/system/hwl-sleep.service >/dev/null <<'U'
[Unit]
Description=HEH-Live sleep mode: do what this time of night calls for
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/hwl-sleep tick
TimeoutStartSec=30min
U
sudo tee /etc/systemd/system/hwl-sleep.timer >/dev/null <<'U'
[Unit]
Description=HEH-Live sleep mode change-over times (UK)
[Timer]
OnCalendar=*-*-* 20:00:00 Europe/London
OnCalendar=*-*-* 23:00:00 Europe/London
OnCalendar=*-*-* 00:00:00 Europe/London
OnCalendar=*-*-* 01:00:00 Europe/London
OnCalendar=*-*-* 03:00:00 Europe/London
OnCalendar=*-*-* 05:40:00 Europe/London
[Install]
WantedBy=timers.target
U
sudo tee /etc/systemd/system/hwl-sleep-boot.service >/dev/null <<'U'
[Unit]
Description=HEH-Live sleep mode: after a restart, put things back the way they should be for this time
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/hwl-sleep boot
TimeoutStartSec=30min
[Install]
WantedBy=multi-user.target
U
sudo systemctl daemon-reload
sudo systemctl enable --now hwl-sleep.timer >/dev/null 2>&1
sudo systemctl enable hwl-sleep-boot.service >/dev/null 2>&1
sudo /usr/local/bin/hwl-sleep tick
sudo /usr/local/bin/hwl-sleep now
systemctl list-timers 'hwl-sleep*' --no-pager | head -3
echo "Sleep mode installed. School nights: 20-23 maintenance, 23-03 sleep. Fri/Sat/Sun and holidays: 00-01 maintenance, 01-03 sleep. 03:00-05:40 deep, back by 6. Check with: sudo hwl-sleep status"
