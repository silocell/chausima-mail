#!/bin/bash
# Quick health check for Chausima Mail (prints no secrets)
H=mail.chausima.com
curl -s -o /dev/null https://$H/jmap/session; sleep 1
echo "last web visitor IP seen by Stalwart: $(tail -n 300 /mnt/launchpad-data/stalwart/logs/stalwart.log.$(date -u +%F) | grep -oE 'listenerId = "http", localPort = 8080, remoteIp = [0-9a-f.:]+' | tail -1 | sed 's/.*remoteIp = //')"
for p in 993 995 465; do echo "port $p: $(echo | timeout 6 openssl s_client -connect 127.0.0.1:$p -servername $H 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ' || echo none)"; done
echo "port 25 STARTTLS: $(echo | timeout 8 openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername $H 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo none)"
echo "published ports: $(docker port stalwart | awk '{print $1}' | sort -u | tr '\n' ' ')"
