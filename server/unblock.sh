#!/bin/bash
# Gets Chausima Mail's web side back after Stalwart bans Caddy's address
# (every web visitor reaches Stalwart through Caddy, so one ban locks everyone out).
#  1) Caddy turns away scanner paths (.env, .php, wp-*) itself.
#  2) Caddy reaches Stalwart over its own private network 172.30.0.0/24.
set -e
CF=/etc/caddy/Caddyfile
docker network inspect chausima-net >/dev/null 2>&1 || docker network create --subnet 172.30.0.0/24 chausima-net >/dev/null
docker inspect -f '{{json .NetworkSettings.Networks}}' stalwart | grep -q chausima-net || docker network connect --ip 172.30.0.10 chausima-net stalwart
echo "stalwart on chausima-net: $(docker inspect -f '{{(index .NetworkSettings.Networks "chausima-net").IPAddress}}' stalwart)"
cp $CF $CF.before-unblock
python3 - "$CF" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
i=s.index('mail.chausima.com'); j=s.index('\n}',i)
blk=s[i:j]
n=blk.count('127.0.0.1:8080'); blk=blk.replace('127.0.0.1:8080','172.30.0.10:8080')
if 'chausima-scanblock' not in blk:
    add='\t# chausima-scanblock\n\t@scan path *.env */.env* *.php */wp-* /wordpress* /.git* /.aws* /cgi-bin* /phpmyadmin* *.asp *.aspx /actuator* /server-status /.DS_Store\n\thandle @scan {\n\t\trespond 404\n\t}\n'
    k=blk.index('{')+1; nl=blk.index('\n',k)+1
    blk=blk[:nl]+add+blk[nl:]
s=s[:i]+blk+s[j:]; open(p,'w').write(s); print("Caddy: proxy lines changed:",n)
PY
if caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then echo "Caddy reloaded"
else cp $CF.before-unblock $CF; systemctl reload caddy; echo "Caddy: didn't validate - put back"; fi
sleep 2
for u in /jmap/session /wordpress/.env /index.php / /login; do echo "$u -> $(curl -s -o /dev/null -w '%{http_code}' https://mail.chausima.com$u)"; done
