#!/usr/bin/env bash
# Chausima Search: puts YaCy in private "web portal" (Robinson) mode.
# It then only searches our own index: no sharing with the public YaCy network,
# no fetching other peers' results, no remote crawl jobs, no UPnP. Safe to re-run.
set -euo pipefail
CONF=/mnt/launchpad-data/yacy/SETTINGS/yacy.conf
sudo test -f "$CONF" || { echo "no yacy.conf yet - start YaCy once first"; exit 1; }
sudo docker stop -t 60 yacy >/dev/null
sudo cp "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
set_kv(){ if sudo grep -qE "^$1[[:space:]]*=" "$CONF"; then sudo sed -i -E "s|^$1[[:space:]]*=.*|$1=$2|" "$CONF"; else echo "$1=$2" | sudo tee -a "$CONF" >/dev/null; fi; }
set_kv network.unit.definition defaults/yacy.network.webportal.unit
set_kv core.service.rwi.tmp false
set_kv allowDistributeIndex false
set_kv allowReceiveIndex false
set_kv allowReceiveIndex.search false
set_kv search.verify ifexist
set_kv search.verify.delete false
set_kv heuristic.site false
set_kv heuristic.opensearch false
set_kv heuristic.searchresults false
set_kv greedylearning.active false
set_kv crawlOrder false
set_kv crawlResponse false
set_kv upnp.enabled false
set_kv javastart_Xmx Xmx1100m
sudo docker start yacy >/dev/null
echo "waiting for YaCy..."; for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8090/ && break; sleep 5; done
sudo grep -E "^(network.unit.definition|allowDistributeIndex|allowReceiveIndex|crawlOrder|upnp.enabled|javastart_Xmx)=" "$CONF"
curl -s "http://127.0.0.1:8090/yacysearch.json?query=test&resource=local" | head -c 300; echo
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' yacy
