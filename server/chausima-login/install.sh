#!/usr/bin/env bash
# Installs the chausima-login function (Sign in with Chausima). Safe to re-run.
set -e
SB=/home/opc/supabase; HERE="$(cd "$(dirname "$0")" && pwd)"
# wrong-password counts live in the database so they survive restarts (only the service role can see them)
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
create table if not exists public.login_tries (id bigserial primary key, account text not null, ip text not null, at timestamptz not null default now());
create index if not exists login_tries_account_at on public.login_tries (account, at);
create index if not exists login_tries_ip_at on public.login_tries (ip, at);
create index if not exists login_tries_at on public.login_tries (at);
alter table public.login_tries enable row level security;
revoke all on public.login_tries from anon, authenticated, public;
grant all on public.login_tries to service_role;
grant usage, select on sequence public.login_tries_id_seq to service_role;
delete from public.login_tries where at < now() - interval '7 days';
SQL
echo "wrong-password counter: ready"
mkdir -p $SB/volumes/functions/chausima-login
install -m 644 "$HERE/chausima-login/index.ts" $SB/volumes/functions/chausima-login/index.ts
chown -R opc:opc $SB/volumes/functions/chausima-login
chcon -R --reference=$SB/volumes/functions/helpdesk $SB/volumes/functions/chausima-login 2>/dev/null || true
SVC=$(docker inspect supabase-edge-functions --format '{{index .Config.Labels "com.docker.compose.service"}}')
( cd $SB && docker compose up -d --force-recreate --no-deps "$SVC" 2>&1 | tail -2 )
sleep 10; echo "functions: $(docker inspect -f '{{.State.Status}}' supabase-edge-functions)"
ANON=$(grep '^ANON_KEY=' $SB/.env | cut -d= -f2-)
echo "no sign-in -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'content-type: application/json' -d '{"email":"nobody","password":"x"}' https://hehs-live.duckdns.org/functions/v1/chausima-login) (should be 200 with a 'don't match' answer)"
echo "helpdesk still -> $(curl -s -o /dev/null -w '%{http_code}' https://hehs-live.duckdns.org/functions/v1/helpdesk)"
