-- FlowLine Suite: Progetti e attività (al posto di Notion › Progetti › Project Tracker).
-- Richiede la migrazione 20261104100000_team_calendario_notifiche.sql (team_members, notifiche, team_is_member).
-- Da eseguire una volta nel SQL Editor del progetto Supabase "Lead Flowline". Si può rieseguire senza danni.
--
-- Come è pensato (semplice di proposito):
--  * progetti: nome, cliente, stato (demo, attivo, assistenza, pausa, chiuso), urgente, persone, cartella Drive.
--  * attivita: una riga per attività, sempre dentro un progetto. Quattro stati: da_fare, in_corso, in_attesa, fatto.
--    Persone, scadenza facoltativa, urgente sì/no, note, file di Drive collegati.
--  * Tutta la squadra vede e modifica tutto, come nel Calendario.
--  * Quando qualcuno ti aggiunge a un'attività ricevi una notifica (campanella), tranne se ti aggiungi da solo.
--
-- Dopo questa migrazione, per caricare i progetti e le attività aperte di Notion:
--   eseguire 20261107100500_progetti_import_notion.sql

------------------------------------------------------------------------
-- Progetti
------------------------------------------------------------------------
create table if not exists public.progetti (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  nome               text not null check (length(trim(nome)) between 1 and 200),
  cliente            text not null default '',
  stato              text not null default 'attivo' check (stato in ('demo','attivo','assistenza','pausa','chiuso')),
  urgente            boolean not null default false,
  inizio             date,
  link               text,                                   -- indirizzo dell'app o del sito del progetto
  persone            uuid[] not null default '{}',          -- chi ci lavora (team_members.id)
  drive_id           text,                                   -- cartella Google Drive del progetto
  drive_nome         text,
  drive_percorso     text,                                   -- es. "Drive condiviso › Progetti"
  drive_cartelle     jsonb not null default '[]'::jsonb,     -- sottocartelle: [{"n":"Contratto firmato","id":"…"}]
  note               text,
  completate_notion  integer not null default 0,             -- attività già chiuse in Notion, solo come conteggio
  notion_id          text,
  creato_da          uuid references public.team_members(id) on delete set null
);
create unique index if not exists progetti_notion_id_key on public.progetti (notion_id) where notion_id is not null;
create index if not exists progetti_stato_idx on public.progetti (stato);
alter table public.progetti enable row level security;
revoke all on public.progetti from anon;

drop policy if exists progetti_all on public.progetti;
create policy progetti_all on public.progetti for all to authenticated
  using (public.team_is_member()) with check (public.team_is_member());

------------------------------------------------------------------------
-- Attività
------------------------------------------------------------------------
create table if not exists public.attivita (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  progetto_id  bigint not null references public.progetti(id) on delete cascade,
  titolo       text not null check (length(trim(titolo)) between 1 and 500),
  stato        text not null default 'da_fare' check (stato in ('da_fare','in_corso','in_attesa','fatto')),
  urgente      boolean not null default false,
  scadenza     date,
  persone      uuid[] not null default '{}',
  note         text,
  file         jsonb not null default '[]'::jsonb,           -- file e cartelle di Drive: [{"n":"nome","url":"https://…"}]
  fatto_il     timestamptz,
  creato_da    uuid references public.team_members(id) on delete set null,
  notion_id    text
);
create unique index if not exists attivita_notion_id_key on public.attivita (notion_id) where notion_id is not null;
create index if not exists attivita_progetto_idx on public.attivita (progetto_id);
create index if not exists attivita_aperte_idx on public.attivita (stato) where stato <> 'fatto';
create index if not exists attivita_persone_idx on public.attivita using gin (persone);
alter table public.attivita enable row level security;
revoke all on public.attivita from anon;

drop policy if exists attivita_all on public.attivita;
create policy attivita_all on public.attivita for all to authenticated
  using (public.team_is_member()) with check (public.team_is_member());

------------------------------------------------------------------------
-- Date di modifica, autore, data di completamento
------------------------------------------------------------------------
create or replace function public.progetti_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.creato_da is null then new.creato_da := auth.uid(); end if;
  new.persone := coalesce(new.persone, '{}');
  return new;
end $$;
revoke all on function public.progetti_before_write() from public, anon, authenticated;
drop trigger if exists progetti_bw on public.progetti;
create trigger progetti_bw before insert or update on public.progetti for each row execute function public.progetti_before_write();

create or replace function public.attivita_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.creato_da is null then new.creato_da := auth.uid(); end if;
  new.persone := coalesce(new.persone, '{}');
  if new.stato = 'fatto' and (tg_op = 'INSERT' or old.stato <> 'fatto') then
    new.fatto_il := coalesce(new.fatto_il, now());
  elsif new.stato <> 'fatto' then
    new.fatto_il := null;
  end if;
  return new;
end $$;
revoke all on function public.attivita_before_write() from public, anon, authenticated;
drop trigger if exists attivita_bw on public.attivita;
create trigger attivita_bw before insert or update on public.attivita for each row execute function public.attivita_before_write();

------------------------------------------------------------------------
-- Notifica: qualcuno ti aggiunge a un'attività
------------------------------------------------------------------------
create or replace function public.attivita_notifica_persone()
returns trigger language plpgsql security definer set search_path = public as $$
declare pn text; nuovi uuid[];
begin
  if auth.uid() is null then return new; end if;            -- importazioni e flussi automatici: niente notifiche
  if new.stato = 'fatto' then return new; end if;
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(u), '{}') into nuovi from unnest(new.persone) u where not (u = any(old.persone));
  else
    nuovi := new.persone;
  end if;
  if coalesce(array_length(nuovi, 1), 0) = 0 then return new; end if;
  select nome into pn from public.progetti where id = new.progetto_id;
  insert into public.notifiche (user_id, tipo, titolo, testo, rif_tipo, rif_id)
  select u, 'attivita_assegnata', 'Nuova attività',
         'Ti è stata assegnata un''attività: ' || new.titolo || coalesce(', nel progetto ' || pn, '') || '.',
         'attivita', new.id
  from unnest(nuovi) u
  where u is distinct from auth.uid()
    and exists (select 1 from public.team_members t where t.id = u and t.attivo);
  return new;
end $$;
revoke all on function public.attivita_notifica_persone() from public, anon, authenticated;
drop trigger if exists attivita_notifica on public.attivita;
create trigger attivita_notifica after insert or update of persone on public.attivita
  for each row execute function public.attivita_notifica_persone();

------------------------------------------------------------------------
-- Il Calendario aveva già riservato eventi.progetto_id: ora punta ai progetti
------------------------------------------------------------------------
do $$ begin
  alter table public.eventi add constraint eventi_progetto_fk foreign key (progetto_id) references public.progetti(id) on delete set null;
exception when duplicate_object then null; when undefined_table then null; when undefined_column then null; end $$;

------------------------------------------------------------------------
-- Aggiornamenti in tempo reale
------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.progetti;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.attivita;
exception when duplicate_object then null; when undefined_object then null; end $$;
