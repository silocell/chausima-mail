#!/usr/bin/env bash
# Chausima Search: make YaCy give way to the Launchpad, AI and mail (for a school day with ~6 pupils on).
#  - lowest CPU priority (cpu-shares 128 vs the normal 1024): anything else that needs the processor goes first
#  - hard cap 0.5 of the one core
#  - 120 pages a minute instead of 300/600
# No restart needed. Undo with: sudo docker update --cpu-shares 1024 --cpus 0.7 yacy
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
sudo docker update --cpu-shares 128 --cpus 0.5 yacy >/dev/null && echo "YaCy now gives way (priority low, max half a core)"
echo "speed: $(curl -s -o /dev/null -w '%{http_code}' --digest -u "admin:$PW" -G http://127.0.0.1:8090/Crawler_p.html -d crawlingPerformance=custom -d customPPM=120) (120 pages a minute)"
sleep 20; uptime
sudo docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' yacy supabase-db supabase-edge-functions stalwart 2>/dev/null
echo "Launchpad answers in: $(curl -s -o /dev/null -w '%{time_total}s' https://hehs-live.duckdns.org/auth/v1/health)"
