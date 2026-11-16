#!/usr/bin/env bash
# Chausima Search: quick progress report (read-only).
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
echo "== crawl script log"; tail -22 ~/yacy-crawl.log 2>/dev/null
echo "== server"; uptime; free -m | sed -n 2p
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' yacy supabase-db 2>/dev/null
sudo du -sh /mnt/launchpad-data/yacy 2>/dev/null
echo "== yacy"
curl -s --digest -u "admin:$PW" http://127.0.0.1:8090/api/status_p.json | tr ',{}' '\n\n\n' | grep -E '"(loaderqueue|localcrawlerqueue|ppm|urlpublictext|rwipublictext|memoryFree|indexingqueue)"' | tr '\n' ' '; echo
curl -s --digest -u "admin:$PW" "http://127.0.0.1:8090/IndexImportMediawiki_p.html" | grep -oE '(Running|Finished|thread|[0-9]+ (articles|documents|count)|[0-9.]+% )[^<]{0,60}' | head -4
curl -s "http://127.0.0.1:8090/yacysearch.json?query=volcano&resource=local&maximumRecords=3" | grep -oE '"(totalResults|title)": *"[^"]*"' | head -4
