#!/usr/bin/env bash
# READ-ONLY: writes the Launchpad database's *rules* (who can see/add what) to a hidden web address for Claude to read.
# No rows, no pupils' data: only table structure, access policies and the account-check functions.
# The file is at a random address on net.chausima.com and deletes itself after 1 hour.   Run:  sudo bash launchpad-rules.sh
set -e
R=$(openssl rand -hex 16); OUT=/srv/hwl-net/rules-$R.txt
q() { docker exec -i supabase-db psql -U postgres -d postgres -X -q -A -t -c "$1"; }
{
echo "### triggers on auth.users"
q "select tgname, pg_get_triggerdef(t.oid) from pg_trigger t where tgrelid='auth.users'::regclass and not tgisinternal"
echo; echo "### their functions"
q "select pg_get_functiondef(t.tgfoid) from pg_trigger t where tgrelid='auth.users'::regclass and not tgisinternal"
echo; echo "### public tables (rls on?)"
q "select c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' order by 1"
echo; echo "### columns of profiles, rooms, messages, posts, replies, shared_links, videos"
q "select table_name, string_agg(column_name||':'||data_type, ', ' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name in ('profiles','rooms','messages','posts','replies','shared_links','videos','links','approved','allowed','sandbox_games','games') group by 1"
echo; echo "### policies"
q "select tablename||' | '||policyname||' | '||cmd||' | '||array_to_string(roles,',')||' | using: '||coalesce(qual,'-')||' | check: '||coalesce(with_check,'-') from pg_policies where schemaname='public' order by tablename, policyname"
echo; echo "### functions used for access (owner/approved/blocked checks)"
q "select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1"
echo; for f in is_owner is_approved is_blocked can_chat my_features staff_tags board_get; do
  q "select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='$f'" 2>/dev/null
done
} > $OUT 2>&1
chmod 644 $OUT; chcon -t httpd_sys_content_t $OUT 2>/dev/null || true
systemd-run --on-active=1h --unit=rules-cleanup-$R /bin/rm -f $OUT >/dev/null 2>&1 || (sleep 3600; rm -f $OUT) &
echo "Done ($(wc -l < $OUT) lines). Tell Claude this code: $R"
