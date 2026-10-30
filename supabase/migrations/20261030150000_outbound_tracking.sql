-- Statistiche anonime dell'outbound (già applicata): stesso principio della newsletter.
-- Ogni email ha un codice casuale (nonce) che NON viene salvato con il contatto.
create table if not exists public.outbound_events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  type text not null check (type in ('sent','open','click')),
  step smallint not null check (step between 0 and 20),
  nonce text not null check (nonce ~ '^[a-z0-9]{8,40}$'),
  url text,
  bot boolean not null default false
);
create index if not exists outbound_events_nonce_idx on public.outbound_events (nonce);
create index if not exists outbound_events_created_idx on public.outbound_events (created_at);
alter table public.outbound_events enable row level security;
create unique index if not exists outbound_events_sent_uniq on public.outbound_events (nonce) where type = 'sent';

create table if not exists public.outbound_link_hosts (host text primary key);
alter table public.outbound_link_hosts enable row level security;
insert into public.outbound_link_hosts (host) values
  ('flowline.it'),('linkedin.com'),('instagram.com'),('facebook.com'),('calendly.com'),('cal.com'),('wa.me'),('flowline-it.github.io')
on conflict do nothing;

create or replace function public.outbound_track_sent(p_step int, p_nonce text)
returns void language sql security definer set search_path = public as $$
  insert into public.outbound_events (type, step, nonce)
  select 'sent', p_step, lower(p_nonce)
  where p_step between 0 and 20 and lower(p_nonce) ~ '^[a-z0-9]{8,40}$'
  on conflict do nothing;
$$;

create or replace function public.outbound_stats(p_since timestamptz default null)
returns table(step int, sent bigint, opens_unique bigint, opens_total bigint, clicks_unique bigint, clicks_total bigint, bots bigint)
language sql stable security definer set search_path = public as $$
  with s as (select nonce, step from public.outbound_events where type = 'sent' and (p_since is null or created_at >= p_since)),
  e as (select ev.* from public.outbound_events ev join s using (nonce) where ev.type in ('open','click'))
  select s.step::int,
         count(distinct s.nonce),
         (select count(distinct e.nonce) from e where e.step = s.step and not e.bot),
         (select count(*) from e where e.step = s.step and e.type = 'open' and not e.bot),
         (select count(distinct e.nonce) from e where e.step = s.step and e.type = 'click' and not e.bot),
         (select count(*) from e where e.step = s.step and e.type = 'click' and not e.bot),
         (select count(*) from e where e.step = s.step and e.bot)
  from s group by s.step order by s.step;
$$;

create or replace function public.outbound_link_stats(p_since timestamptz default null)
returns table(url text, clicks_total bigint, clicks_unique bigint)
language sql stable security definer set search_path = public as $$
  select ev.url, count(*), count(distinct ev.nonce)
  from public.outbound_events ev
  where ev.type = 'click' and not ev.bot and (p_since is null or ev.created_at >= p_since)
    and exists (select 1 from public.outbound_events s where s.type = 'sent' and s.nonce = ev.nonce)
  group by ev.url order by 2 desc, 1;
$$;

revoke all on function public.outbound_track_sent(int, text) from public;
revoke all on function public.outbound_stats(timestamptz) from public;
revoke all on function public.outbound_link_stats(timestamptz) from public;
grant execute on function public.outbound_track_sent(int, text) to anon, authenticated;
grant execute on function public.outbound_stats(timestamptz) to anon, authenticated;
grant execute on function public.outbound_link_stats(timestamptz) to anon, authenticated;
