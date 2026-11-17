#!/usr/bin/env bash
# read-only: how YaCy stores outgoing links, and current state
PW=$(sudo sed -n 's/^YACY_ADMIN_PASS=//p' /etc/chausima-yacy.env)
A="--digest -u admin:$PW"
echo "== hwlai uses yacy: $(grep -c 'our own search engine (YaCy' /home/opc/supabase/volumes/functions/hwchat/index.ts)"
echo "== mode log"; tail -3 /var/log/yacy-mode.log 2>/dev/null
echo "== solr outbound fields"
curl -s $A "http://127.0.0.1:8090/solr/select?core=collection1&q=*:*&rows=1&wt=json&fl=sku,host_s,outboundlinks_urlstub_sxt,outboundlinks_protocol_sxt" | head -c 700; echo
echo "== facet on outbound hosts?"
curl -s $A "http://127.0.0.1:8090/solr/select?core=collection1&q=*:*&rows=0&wt=json&facet=true&facet.field=host_s&facet.limit=5" | head -c 500; echo
echo "== docs"; curl -s $A "http://127.0.0.1:8090/api/status_p.json" | tr ',{}' '\n\n\n' | grep -E '"(urlpublictext|rwipublictext|ppm|localcrawlerqueue|loaderqueue)"' | tr '\n' ' '; echo
sudo du -sh /mnt/launchpad-data/yacy; uptime
