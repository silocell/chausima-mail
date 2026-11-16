#!/bin/bash
# Chausima Search: adds https://hehs-live.duckdns.org/search/v1?query=... to Caddy.
# Only YaCy's JSON search answer is reachable; YaCy's admin pages and crawler are not.
# Validates before reloading, and puts the old Caddyfile back if the check fails.
CF=/etc/caddy/Caddyfile
sudo cp $CF $CF.before-search
sudo python3 - "$CF" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
if 'chausima-search' in s: print("Caddy: search route already there"); sys.exit()
m=re.search(r'(?m)^[^\n#]*hehs-live\.duckdns\.org[^\n]*\{[ \t]*\n', s)
if not m: print("Caddy: hehs-live block not found"); sys.exit(1)
add='''\t# chausima-search: only the JSON search answer from YaCy
\thandle /search/v1 {
\t\theader Access-Control-Allow-Origin "*"
\t\theader Access-Control-Allow-Methods "GET, OPTIONS"
\t\t@opt method OPTIONS
\t\trespond @opt 204
\t\t@notget not method GET
\t\trespond @notget 405
\t\theader Cache-Control "public, max-age=300"
\t\trewrite * /yacysearch.json?{query}&resource=local&contentdom=text&verify=false&nav=none
\t\treverse_proxy 127.0.0.1:8090 {
\t\t\theader_down -Set-Cookie
\t\t}
\t}
'''
s=s[:m.end()]+add+s[m.end():]; open(p,'w').write(s); print("Caddy: search route added")
PY
if sudo caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && sudo systemctl reload caddy; then echo "Caddy reloaded"
else sudo cp $CF.before-search $CF; sudo systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 2
c=$(curl -s -o /tmp/s.json -w '%{http_code}' "https://hehs-live.duckdns.org/search/v1?query=test")
echo "search -> $c $(head -c 120 /tmp/s.json | tr '\n' ' ')"
a=$(curl -s -o /dev/null -w '%{http_code}' "https://hehs-live.duckdns.org/auth/v1/health"); echo "auth still -> $a"
y=$(curl -s -o /dev/null -w '%{http_code}' "https://hehs-live.duckdns.org/Crawler_p.html"); echo "yacy admin from outside -> $y (should not be 200)"
if [ "$c" != 200 ] || [ "$y" = 200 ]; then sudo cp $CF.before-search $CF; sudo systemctl reload caddy; echo "check failed - Caddy put back"; fi
