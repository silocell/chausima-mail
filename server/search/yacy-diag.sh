#!/usr/bin/env bash
# Chausima Search: why isn't YaCy indexing? (read-only)
Y(){ sudo docker exec yacy curl -s "http://127.0.0.1:8090/$1"; }
echo "== status (local admin)"; Y api/status_p.json | tr ',{}' '\n\n\n' | grep -E '"(loaderqueue|localcrawlerqueue|indexingqueue|ppm|urlpublictext|rwipublictext|crawlerpaused|crawlerpaused_local)"' | tr '\n' ' '; echo
echo "== crawl profiles"; Y "Crawler_p.html" | grep -oE 'crawlingURL[^<]{0,80}|"crawl[A-Za-z]*Paused[^,]*' | head -5
Y "api/latency_p.xml" | head -c 300; echo
echo "== pause state"; Y "Status.html" | grep -oiE '(crawl[^<]{0,40}paus[^<]{0,40}|paused[^<]{0,60})' | head -5
echo "== log errors / crawl lines"
sudo sh -c 'tail -n 4000 /mnt/launchpad-data/yacy/LOG/yacy00.log' | grep -iE 'error|exception|crawl|import|surrogate|robots|denied|transaction|refused' | tail -25
echo "== surrogates"; sudo ls /mnt/launchpad-data/yacy/SURROGATES/in /mnt/launchpad-data/yacy/SURROGATES/out 2>/dev/null | head
sudo du -sh /mnt/launchpad-data/yacy/INDEX 2>/dev/null
