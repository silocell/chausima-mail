#!/bin/bash
# Makes Caddy pass each visitor's real IP to Stalwart using the PROXY protocol,
# so Stalwart's automatic bans hit the attacker, never Caddy. Rolls back if checks fail.
CF=/etc/caddy/Caddyfile
cp $CF $CF.before-proxyproto
python3 - "$CF" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
i=s.index('mail.chausima.com'); j=s.index('\n}',i); blk=s[i:j]
if 'proxy_protocol' in blk: print("Caddy: already sends PROXY protocol"); sys.exit()
# reverse_proxy 172.30.0.10:8080            -> block form with transport
# reverse_proxy 172.30.0.10:8080 { ... }     -> add transport inside
def fix(m):
    ind=m.group(1); rest=m.group(3)
    if rest.strip().startswith('{'):
        return f"{ind}reverse_proxy 172.30.0.10:8080 {{\n{ind}\ttransport http {{\n{ind}\t\tproxy_protocol v2\n{ind}\t}}"
    return f"{ind}reverse_proxy 172.30.0.10:8080 {{\n{ind}\ttransport http {{\n{ind}\t\tproxy_protocol v2\n{ind}\t}}\n{ind}}}{rest}"
blk2,n=re.subn(r'(?m)^([ \t]*)reverse_proxy (172\.30\.0\.10:8080)([^\n]*)', lambda m: fix(m) if not m.group(3).strip().startswith('{') else f"{m.group(1)}reverse_proxy 172.30.0.10:8080 {{\n{m.group(1)}\ttransport http {{\n{m.group(1)}\t\tproxy_protocol v2\n{m.group(1)}\t}}", blk)
s=s[:i]+blk2+s[j:]; open(p,'w').write(s); print("Caddy: PROXY protocol added to",n,"proxy line(s)")
PY
if caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then echo "Caddy reloaded"
else cp $CF.before-proxyproto $CF; systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 2
c=$(curl -s -o /dev/null -w '%{http_code}' https://mail.chausima.com/jmap/session); echo "/jmap/session -> $c"
if [ "$1" = check ] && [ "$c" != 200 ]; then cp $CF.before-proxyproto $CF; systemctl reload caddy; echo "check failed - Caddy put back"; fi
