#!/usr/bin/env bash
# Chausima Search: installs YaCy on HEH-Live as a private search engine.
#  - index lives on the data disk (/mnt/launchpad-data/yacy)
#  - capped at 1.5 GB memory and 0.7 CPU so Supabase and mail stay fast
#  - only reachable from the server itself (127.0.0.1:8090) and Caddy (chausima-net)
#  - admin password is random, kept in /etc/chausima-yacy.env (root only), never printed
# Never touches firewalld. Safe to re-run.
set -euo pipefail
IMG=yacy/yacy_search_server:aarch64-latest
D=/mnt/launchpad-data/yacy
mountpoint -q /mnt/launchpad-data || { echo "data disk not mounted"; exit 1; }
sudo docker pull -q "$IMG"
U=$(sudo docker run --rm --entrypoint id "$IMG" -u); G=$(sudo docker run --rm --entrypoint id "$IMG" -g)
sudo mkdir -p "$D"; sudo chown -R "$U:$G" "$D"
sudo docker rm -f yacy >/dev/null 2>&1 || true
sudo docker run -d --name yacy --network chausima-net --ip 172.30.0.20 -p 127.0.0.1:8090:8090 \
  -v "$D":/opt/yacy_search_server/DATA --memory 1600m --memory-swap 2400m --cpus 0.7 \
  --restart unless-stopped --log-opt max-size=50m --log-opt max-file=2 "$IMG" >/dev/null
echo "waiting for YaCy to start..."
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8090/ && break; sleep 5; done
if [ ! -f /etc/chausima-yacy.env ]; then
  PW=$(openssl rand -hex 16)
  echo "YACY_ADMIN_PASS=$PW" | sudo tee /etc/chausima-yacy.env >/dev/null; sudo chmod 600 /etc/chausima-yacy.env
fi
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
sudo docker exec yacy /opt/yacy_search_server/bin/passwd.sh "$PW" >/dev/null 2>&1 && echo "admin password set (stored in /etc/chausima-yacy.env)" || echo "PASSWD-FAILED"
echo "--- check ---"
sudo docker ps --filter name=yacy --format '{{.Names}} {{.Status}}'
echo "uid=$U tools: $(sudo docker exec yacy sh -c 'command -v curl wget' | tr '\n' ' ')"
curl -s -o /dev/null -w "search page %{http_code}\n" "http://127.0.0.1:8090/yacysearch.json?query=test"
curl -s --digest -u "admin:$PW" -o /dev/null -w "admin api %{http_code}\n" http://127.0.0.1:8090/api/status_p.json
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' yacy
