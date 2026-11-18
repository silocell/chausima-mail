#!/usr/bin/env bash
# Launchpad sign-ups by year group. Hatch End addresses start with the year they joined: 26xxxx = Year 7, 25xxxx = Year 8, ...
#  - table public.signup_years: which year groups can sign up (switched on and off from HWL Admin -> People)
#  - check_year_group() now lets in any open year group (shivkforindia@gmail.com and the signup_allow list as before)
#  - shiv@chausima.com goes on the allow list as a normal account (it still needs approving like anyone else)
# The old rule is saved to /var/backups first. Safe to re-run. Run:  sudo bash install.sh
set -e
mkdir -p /var/backups
B=/var/backups/check_year_group-$(date +%Y%m%d-%H%M%S).sql
docker exec supabase-db psql -U postgres -d postgres -tAc "select pg_get_functiondef('public.check_year_group'::regproc)" > $B
echo "old rule saved: $B  (put it back with: sudo docker exec -i supabase-db psql -U postgres -d postgres < $B)"
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
create table if not exists public.signup_years (
  prefix text primary key check (prefix ~ '^[0-9]{2}$'),
  label  text not null check (char_length(label) between 1 and 40),
  open   boolean not null default true
);
alter table public.signup_years enable row level security;
revoke all on public.signup_years from anon, authenticated, public;
grant all on public.signup_years to service_role;
insert into public.signup_years (prefix, label, open) values ('26', 'Year 7', true), ('25', 'Year 8', true)
  on conflict (prefix) do nothing;

create or replace function public.check_year_group() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare m text[];
begin
  /* ascii_guard */ if new.email is not null and new.email !~ '^[!-~]+$' then raise exception 'Sign-ups are limited to Hatch End addresses in the open year groups.'; end if;
  if lower(new.email) = 'shivkforindia@gmail.com' then
    return new;
  end if;
  m := regexp_match(lower(new.email), '^([0-9]{2})[a-z]{4}@hatchend\.harrow\.sch\.uk$');
  if m is not null and exists (select 1 from public.signup_years where prefix = m[1] and open) then
    return new;
  end if;
  if exists (select 1 from public.signup_allow where email = lower(new.email)) then
    return new;
  end if;
  raise exception 'Sign-ups are limited to Hatch End addresses in the open year groups.';
end;
$function$;

insert into public.signup_allow (email) select 'shiv@chausima.com'
  where not exists (select 1 from public.signup_allow where email = 'shiv@chausima.com');
SQL
echo "open year groups:"; docker exec supabase-db psql -U postgres -d postgres -tAc "select prefix||' = '||label||case when open then ' (open)' else ' (closed)' end from public.signup_years order by prefix desc"
echo "allow list:"; docker exec supabase-db psql -U postgres -d postgres -tAc "select email from public.signup_allow"
