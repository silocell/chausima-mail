#!/usr/bin/env bash
# Chausima Suite = CryptPad (AGPL-3.0, https://cryptpad.org) on HEH-Live, with "Sign in with Chausima".
#   https://suite.chausima.com          the Suite
#   https://suite-sandbox.chausima.com  CryptPad's sandbox (keeps documents safely separated; required by CryptPad)
# Signing in uses Chausima ID (CryptPad's official SSO plugin, OpenID Connect). People don't need a second password.
# Data lives in /mnt/launchpad-data/cryptpad. The container listens on 127.0.0.1:3100 only; Caddy serves the domains.
# Docs, Sheets and Slides use the Euro-Office editors (AGPL), downloaded on first start.
# Safe to re-run (keeps data, secrets and settings). Never touches the firewall.   Run:  sudo bash install.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
D=/mnt/launchpad-data/cryptpad; CF=/etc/caddy/Caddyfile; FN=/home/opc/supabase/volumes/functions/chausima-id
MAIN=https://suite.chausima.com; BOX=https://suite-sandbox.chausima.com; VER=2026.10.1
say() { echo "== $*"; }

say "image"
IMG=""
for t in "cryptpad/cryptpad:version-$VER" "cryptpad/cryptpad:latest"; do
  if docker pull -q "$t" >/dev/null 2>&1 && [ "$(docker image inspect -f '{{.Architecture}}' "$t")" = "$(docker info -f '{{.Architecture}}' | sed 's/aarch64/arm64/;s/x86_64/amd64/')" ]; then IMG=$t; break; fi
done
if [ -z "$IMG" ]; then
  say "no ready-made image for this server's processor: building CryptPad $VER (takes 10-20 minutes)"
  rm -rf /tmp/cpsrc && mkdir -p /tmp/cpsrc && curl -sL https://codeload.github.com/cryptpad/cryptpad/tar.gz/refs/tags/$VER | tar xz -C /tmp/cpsrc --strip-components=1
  docker build -q -t chausima/cryptpad:$VER /tmp/cpsrc >/dev/null; IMG=chausima/cryptpad:$VER
fi
echo "using $IMG"

say "folders"
mkdir -p $D/data/blob $D/data/block $D/data/data $D/data/files $D/customize $D/config $D/plugins $D/onlyoffice-dist $D/onlyoffice-conf
if [ ! -f $D/plugins/sso/index.js ]; then
  rm -rf $D/plugins/sso && mkdir -p $D/plugins/sso
  curl -sL https://codeload.github.com/cryptpad/sso/tar.gz/refs/heads/main | tar xz -C $D/plugins/sso --strip-components=1
fi
chown -R 4001:4001 $D
docker run --rm -u 4001:4001 -v $D/plugins/sso:/sso -w /sso --entrypoint npm "$IMG" ci --omit=dev --no-audit --no-fund >/dev/null 2>&1 && echo "SSO plugin ready"

say "settings"
SECRET_FILE=/etc/chausima-suite.env
[ -f $SECRET_FILE ] || { umask 077; echo "SSO_SECRET=$(openssl rand -hex 32)" > $SECRET_FILE; }
SSO_SECRET=$(sed -n 's/^SSO_SECRET=//p' $SECRET_FILE)
example() {   # $1 = config.example.js | infra.example.js -> stdout. Newer images keep them in config.local/
  docker run --rm --entrypoint sh "$IMG" -c "cat /cryptpad/config.local/$1 2>/dev/null || cat /cryptpad/config/$1 2>/dev/null" && return 0
  curl -fsSL "https://raw.githubusercontent.com/cryptpad/cryptpad/2026.10.1/config/$1"
}
[ -s $D/config/config.js ] || rm -f $D/config/config.js
[ -s $D/config/infra.js ] || rm -f $D/config/infra.js
if [ ! -f $D/config/config.js ]; then
  example config.example.js > $D/config/config.js.new && [ -s $D/config/config.js.new ] && mv $D/config/config.js.new $D/config/config.js
  sed -i "s#installMethod: 'unspecified'#installMethod: 'docker-chausima'#; s#logToStdout: false#logToStdout: true#" $D/config/config.js
fi
if [ ! -f $D/config/infra.js ]; then
  example infra.example.js > $D/config/infra.js.new && [ -s $D/config/infra.js.new ] && mv $D/config/infra.js.new $D/config/infra.js
  python3 - "$D/config/infra.js" "$MAIN" "$BOX" <<'P'
import sys,re
p,main,box=sys.argv[1:]; s=open(p).read()
s=s.replace('origin: "http://localhost:3000"','origin: "%s"'%main,1).replace('sandboxOrigin: "http://localhost:3001"','sandboxOrigin: "%s"'%box,1)
s=s.replace('httpHost: "localhost"','httpHost: "0.0.0.0"',1)
assert main in s and box in s and '"0.0.0.0"' in s, "infra.js layout changed"
open(p,'w').write(s)
P
fi
cat > $D/config/sso.js <<EOF
// Sign in with Chausima (Chausima ID). Written by the Chausima installer; re-running it rewrites this file.
module.exports = {
    enabled: true,
    enforced: false,        // turn on "SSO only" in the CryptPad admin panel once your admin account works
    cpPassword: false,      // one account: no second CryptPad password
    forceCpPassword: false,
    list: [{
        name: 'Chausima', type: 'oidc',
        url: 'https://hehs-live.duckdns.org/chausima-id',
        client_id: 'cryptpad', client_secret: '$SSO_SECRET',
        id_token_alg: 'HS256', username_claim: 'name', username_scope: 'profile', use_pkce: true, use_nonce: true
    }]
};
EOF
chown -R 4001:4001 $D/config; chmod 600 $D/config/sso.js

say "tell Chausima ID about the Suite"
python3 - "$FN/clients.json" "$SSO_SECRET" "$MAIN/ssoauth" <<'P'
import sys,json
p,sec,ru=sys.argv[1:]
try: c=json.load(open(p))
except Exception: c={}
c["cryptpad"]={"secret":sec,"redirect":[ru],"name":"Chausima Suite"}
open(p,"w").write(json.dumps(c,indent=1))
P
chmod 644 $FN/clients.json
( cd /home/opc/supabase && docker compose up -d --force-recreate --no-deps functions >/dev/null 2>&1 || docker restart supabase-edge-functions >/dev/null )

# CryptPad's own parts talk to each other on "localhost", which inside the container can mean IPv6 (::1) while they
# listen on IPv4: they never meet and it crashes with INTERFACE_UNEXPECTED_ERROR. Point them at 127.0.0.1 (also fixes old installs).
sed -i 's/host: "localhost"/host: "127.0.0.1"/g' $D/config/infra.js
say "start CryptPad"
docker rm -f cryptpad >/dev/null 2>&1 || true
docker run -d --name cryptpad --hostname cryptpad --restart unless-stopped -p 127.0.0.1:3100:3000 \
  --memory 2500m --cpus 1.5 --ulimit nofile=1000000:1000000 \
  -e CPAD_INSTALL_OFFICE=yes -e CRYPTPAD_SSO_CONFIG=/cryptpad/config/sso.js \
  -v $D/data/blob:/cryptpad/blob -v $D/data/block:/cryptpad/block -v $D/customize:/cryptpad/customize \
  -v $D/data/data:/cryptpad/data -v $D/data/files:/cryptpad/datastore -v $D/config:/cryptpad/config \
  -v $D/onlyoffice-dist:/cryptpad/www/common/onlyoffice/dist -v $D/onlyoffice-conf:/cryptpad/onlyoffice-conf \
  -v $D/plugins/sso:/cryptpad/lib/plugins/sso \
  "$IMG" >/dev/null && echo started

say "Caddy"
cp $CF $CF.before-suite
if ! grep -q '^suite.chausima.com' $CF; then
  cat >> $CF <<'C'

suite.chausima.com, suite-sandbox.chausima.com {
	reverse_proxy 127.0.0.1:3100
}
C
fi
if caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then echo "Caddy reloaded"
else cp $CF.before-suite $CF; systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi

say "waiting for CryptPad (the first start downloads the office editors: up to 10 minutes)"
for i in $(seq 1 120); do c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ || true); [ "$c" = 200 ] && break; sleep 5; done
echo "CryptPad answers: ${c:-nothing}"
if [ "$c" != 200 ]; then echo "--- last log lines ---"; docker logs --tail 25 cryptpad 2>&1; exit 1; fi
echo "suite.chausima.com -> $(curl -s -o /dev/null -w '%{http_code}' $MAIN/)"
sleep 5
T=$(docker logs cryptpad 2>&1 | grep -o 'https://[^ ]*/install/#[A-Za-z0-9+/=_-]*' | tail -1)
if [ -n "$T" ]; then echo; echo "ADMIN SET-UP LINK - open it once, yourself, to make the Suite's admin account (don't share it):"; echo "$T"
else echo "(no set-up link: an admin account already exists)"; fi
