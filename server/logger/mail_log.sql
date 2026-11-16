-- Chausima Mail: info@ log shown in Maintenance -> Mail log.
-- Written only by the logger on the server (service key). Read only through the
-- maillog function, which checks for the owner or an extra admin.
create table if not exists public.mail_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('in','out','wash')),
  mail_id     text,
  mail_from   text,
  mail_to     text,
  subject     text,
  body        text,          -- cleared after 7 days; full copy stays in the log mailbox
  received_at timestamptz,
  aol_status  text not null default 'sending' check (aol_status in ('sending','retrying','delivered','failed','sent')),
  deleted_at  timestamptz
);
create index if not exists mail_log_at on public.mail_log (at desc);
alter table public.mail_log enable row level security;
revoke all on public.mail_log from anon, authenticated;
grant all on public.mail_log to service_role;
grant usage, select on sequence public.mail_log_id_seq to service_role;
select 'mail_log ready' as ok, count(*) from public.mail_log;
