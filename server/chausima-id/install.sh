#!/usr/bin/env bash
# Chausima ID on HEH-Live: Chausima accounts + "Sign in with Chausima" (OpenID Connect) for Chausima tools.
#  - table public.chausima_accounts (only the server can read it; passwords are stored as PBKDF2 hashes)
#  - edge function chausima-id
#  - Caddy: https://hehs-live.duckdns.org/chausima-id/*  ->  the function (the caller's Authorization is passed on
#    as X-Chz-Auth, because the functions gateway needs the anon key in Authorization)
# Safe to re-run. Never touches the firewall. Run:  sudo bash install.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); SB=/home/opc/supabase; FN=$SB/volumes/functions; CF=/etc/caddy/Caddyfile
ANON=$(sed -n 's/^ANON_KEY=//p' $SB/.env | tr -d '"')
echo "== table"
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
create table if not exists public.chausima_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z0-9][a-z0-9._]{2,29}$'),
  name text not null check (char_length(name) between 1 and 60),
  pass text not null,
  created_at timestamptz not null default now(),
  last_login timestamptz,
  disabled boolean not null default false
);
alter table public.chausima_accounts enable row level security;
revoke all on public.chausima_accounts from anon, authenticated, public;
grant all on public.chausima_accounts to service_role;
SQL
echo "table ready"
echo "== function"
mkdir -p $FN/chausima-id
cp "$HERE/chausima-id/index.ts" $FN/chausima-id/index.ts
[ -f $FN/chausima-id/clients.json ] || echo '{}' > $FN/chausima-id/clients.json
chmod 644 $FN/chausima-id/index.ts $FN/chausima-id/clients.json
( cd $SB && docker compose up -d --force-recreate --no-deps functions >/dev/null 2>&1 || docker restart supabase-edge-functions >/dev/null )
echo "== Caddy"
cp $CF $CF.before-chausima-id
if ! grep -q 'chausima-id-route' $CF; then
  python3 - "$CF" "$ANON" <<'P'
import sys,re
p,anon=sys.argv[1],sys.argv[2]; s=open(p).read()
m=re.search(r'(?m)^hehs-live\.duckdns\.org[^\n{]*\{\n', s); assert m, "hehs-live site block not found"
add=('\t# chausima-id-route\n\thandle /chausima-id/* {\n\t\trewrite * /functions/v1{uri}\n'
     '\t\treverse_proxy 127.0.0.1:8000 {\n\t\t\theader_up X-Chz-Auth {http.request.header.Authorization}\n'
     '\t\t\theader_up Authorization "Bearer %s"\n\t\t\theader_up apikey "%s"\n\t\t}\n\t}\n') % (anon, anon)
s=s[:m.end()]+add+s[m.end():]; open(p,'w').write(s); print("route added")
P
fi
if caddy validate --config $CF --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then echo "Caddy reloaded"
else cp $CF.before-chausima-id $CF; systemctl reload caddy; echo "Caddy: didn't validate - put back"; exit 1; fi
sleep 12
c=$(curl -s https://hehs-live.duckdns.org/chausima-id/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"')
echo "Chausima ID: ${c:-NOT answering}"
