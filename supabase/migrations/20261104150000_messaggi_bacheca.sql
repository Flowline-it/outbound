-- Messaggi tra collaboratori e Bacheca comunicazioni della Home.
-- Richiede la migrazione 20261104100000_team_calendario_notifiche.sql (team_members, notifiche, team_is_member).
-- Si può rilanciare più volte senza effetti collaterali.

------------------------------------------------------------------------
-- Messaggi personali: uno scrive, uno riceve. Li vedono solo i due interessati.
------------------------------------------------------------------------
create table if not exists public.messaggi (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  da_id      uuid not null references public.team_members(id) on delete cascade,
  a_id       uuid not null references public.team_members(id) on delete cascade,
  testo      text not null check (length(btrim(testo)) > 0 and length(testo) <= 4000),
  letto_il   timestamptz,
  check (da_id <> a_id)
);
create index if not exists messaggi_a_idx  on public.messaggi (a_id, created_at desc);
create index if not exists messaggi_da_idx on public.messaggi (da_id, created_at desc);
alter table public.messaggi enable row level security;
revoke all on public.messaggi from anon;

drop policy if exists messaggi_select on public.messaggi;
create policy messaggi_select on public.messaggi for select to authenticated
  using (da_id = auth.uid() or a_id = auth.uid());
-- si scrive solo a nome proprio e a una persona della squadra
drop policy if exists messaggi_insert on public.messaggi;
create policy messaggi_insert on public.messaggi for insert to authenticated
  with check (da_id = auth.uid() and public.team_is_member()
              and exists (select 1 from public.team_members t where t.id = a_id and t.attivo));
-- chi ha scritto può cancellare il proprio messaggio; modificarlo no
drop policy if exists messaggi_delete on public.messaggi;
create policy messaggi_delete on public.messaggi for delete to authenticated using (da_id = auth.uid());
revoke update on public.messaggi from authenticated;

-- Il destinatario segna come letti i messaggi ricevuti da una persona (e le relative notifiche).
create or replace function public.messaggi_segna_letti(p_da uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then return 0; end if;
  with u as (
    update public.messaggi set letto_il = now()
    where a_id = auth.uid() and da_id = p_da and letto_il is null returning id
  ), v as (
    update public.notifiche set letta_il = now()
    where user_id = auth.uid() and rif_tipo = 'messaggio' and letta_il is null
      and rif_id in (select id from public.messaggi where a_id = auth.uid() and da_id = p_da)
    returning 1
  )
  select count(*) into n from u;
  return n;
end $$;
revoke all on function public.messaggi_segna_letti(uuid) from public, anon;
grant execute on function public.messaggi_segna_letti(uuid) to authenticated;

------------------------------------------------------------------------
-- Bacheca: comunicazioni per tutta la squadra. Tutti leggono, ognuno gestisce le proprie.
------------------------------------------------------------------------
create table if not exists public.bacheca (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  autore_id  uuid not null references public.team_members(id) on delete cascade,
  titolo     text check (titolo is null or length(titolo) <= 160),
  testo      text not null check (length(btrim(testo)) > 0 and length(testo) <= 4000),
  fissato    boolean not null default false
);
create index if not exists bacheca_idx on public.bacheca (fissato desc, created_at desc);
alter table public.bacheca enable row level security;
revoke all on public.bacheca from anon;

drop policy if exists bacheca_select on public.bacheca;
create policy bacheca_select on public.bacheca for select to authenticated using (public.team_is_member());
drop policy if exists bacheca_insert on public.bacheca;
create policy bacheca_insert on public.bacheca for insert to authenticated
  with check (autore_id = auth.uid() and public.team_is_member());
drop policy if exists bacheca_update on public.bacheca;
create policy bacheca_update on public.bacheca for update to authenticated
  using (autore_id = auth.uid()) with check (autore_id = auth.uid());
drop policy if exists bacheca_delete on public.bacheca;
create policy bacheca_delete on public.bacheca for delete to authenticated using (autore_id = auth.uid());

create or replace function public.bacheca_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists bacheca_bu on public.bacheca;
create trigger bacheca_bu before update on public.bacheca for each row execute function public.bacheca_touch();

------------------------------------------------------------------------
-- Notifiche: le crea solo il database (la campanella le mostra già)
------------------------------------------------------------------------
create or replace function public.messaggi_notifica()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select t.nome into v_nome from public.team_members t where t.id = new.da_id;
  insert into public.notifiche (user_id, tipo, titolo, testo, rif_tipo, rif_id)
  values (new.a_id, 'messaggio', 'Nuovo messaggio da ' || coalesce(v_nome, 'un collega'),
          left(regexp_replace(new.testo, '\s+', ' ', 'g'), 140), 'messaggio', new.id);
  return new;
end $$;
revoke all on function public.messaggi_notifica() from public, anon, authenticated;
drop trigger if exists messaggi_ai on public.messaggi;
create trigger messaggi_ai after insert on public.messaggi for each row execute function public.messaggi_notifica();

create or replace function public.bacheca_notifica()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  select t.nome into v_nome from public.team_members t where t.id = new.autore_id;
  insert into public.notifiche (user_id, tipo, titolo, testo, rif_tipo, rif_id)
  select t.id, 'bacheca', 'Nuova comunicazione da ' || coalesce(v_nome, 'un collega'),
         coalesce(nullif(btrim(new.titolo), ''), left(regexp_replace(new.testo, '\s+', ' ', 'g'), 140)), 'bacheca', new.id
  from public.team_members t where t.attivo and t.id <> new.autore_id;
  return new;
end $$;
revoke all on function public.bacheca_notifica() from public, anon, authenticated;
drop trigger if exists bacheca_ai on public.bacheca;
create trigger bacheca_ai after insert on public.bacheca for each row execute function public.bacheca_notifica();

------------------------------------------------------------------------
-- Aggiornamenti in tempo reale
------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.messaggi;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.bacheca;
exception when duplicate_object then null; when undefined_object then null; end $$;
