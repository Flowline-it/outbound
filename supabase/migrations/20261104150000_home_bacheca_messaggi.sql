-- Home: bacheca delle comunicazioni e messaggi personali tra collaboratori.
-- Si esegue una volta sola nel SQL Editor, dopo la migrazione del Calendario (20261104100000). Si può rilanciare senza danni.
--
--  * bacheca: comunicazioni per tutto il team. Le leggono tutti, le scrive chiunque, le modifica ed elimina solo chi le ha scritte.
--  * messaggi: messaggi personali. Li vedono solo mittente e destinatario; il destinatario li segna come letti.
--  * Le notifiche (campanella) le crea solo il database: una per chi riceve un messaggio, una per tutti gli altri per ogni nuova comunicazione.

------------------------------------------------------------------------
-- Bacheca
------------------------------------------------------------------------
create table if not exists public.bacheca (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  autore      uuid references public.team_members(id) on delete set null,
  titolo      text not null check (length(btrim(titolo)) > 0),
  testo       text not null check (length(btrim(testo)) > 0),
  fissata     boolean not null default false
);
create index if not exists bacheca_created_idx on public.bacheca (fissata desc, created_at desc);
alter table public.bacheca enable row level security;
revoke all on public.bacheca from anon;

drop policy if exists bacheca_select on public.bacheca;
create policy bacheca_select on public.bacheca for select to authenticated using (public.team_is_member());
drop policy if exists bacheca_insert on public.bacheca;
create policy bacheca_insert on public.bacheca for insert to authenticated
  with check (public.team_is_member() and autore = auth.uid());
drop policy if exists bacheca_update on public.bacheca;
create policy bacheca_update on public.bacheca for update to authenticated
  using (autore = auth.uid()) with check (autore = auth.uid());
drop policy if exists bacheca_delete on public.bacheca;
create policy bacheca_delete on public.bacheca for delete to authenticated using (autore = auth.uid());

create or replace function public.bacheca_before_write()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.autore is null then new.autore := auth.uid(); end if;
  return new;
end $$;
drop trigger if exists bacheca_bw on public.bacheca;
create trigger bacheca_bw before insert or update on public.bacheca for each row execute function public.bacheca_before_write();

-- Nuova comunicazione → notifica a tutti gli altri
create or replace function public.notifiche_bacheca()
returns trigger language plpgsql security definer set search_path = public as $$
declare chi text;
begin
  select nome into chi from public.team_members where id = new.autore;
  insert into public.notifiche (user_id, tipo, titolo, testo, rif_tipo, rif_id)
  select t.id, 'bacheca', 'Nuova comunicazione in bacheca',
         coalesce(chi || ': ', '') || left(new.titolo, 120), 'bacheca', new.id
  from public.team_members t
  where t.attivo and t.id is distinct from new.autore;
  return new;
end $$;
revoke all on function public.notifiche_bacheca() from public, anon, authenticated;
drop trigger if exists bacheca_notifica on public.bacheca;
create trigger bacheca_notifica after insert on public.bacheca for each row execute function public.notifiche_bacheca();

------------------------------------------------------------------------
-- Messaggi personali
------------------------------------------------------------------------
create table if not exists public.messaggi (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  da_user     uuid not null references public.team_members(id) on delete cascade,
  a_user      uuid not null references public.team_members(id) on delete cascade,
  testo       text not null check (length(btrim(testo)) > 0),
  letto_il    timestamptz,
  check (da_user <> a_user)
);
create index if not exists messaggi_a_idx on public.messaggi (a_user, created_at desc);
create index if not exists messaggi_da_idx on public.messaggi (da_user, created_at desc);
alter table public.messaggi enable row level security;
revoke all on public.messaggi from anon;

drop policy if exists messaggi_select on public.messaggi;
create policy messaggi_select on public.messaggi for select to authenticated
  using (public.team_is_member() and (da_user = auth.uid() or a_user = auth.uid()));
drop policy if exists messaggi_insert on public.messaggi;
create policy messaggi_insert on public.messaggi for insert to authenticated
  with check (public.team_is_member() and da_user = auth.uid()
              and exists (select 1 from public.team_members t where t.id = a_user and t.attivo));
drop policy if exists messaggi_update on public.messaggi;
create policy messaggi_update on public.messaggi for update to authenticated
  using (a_user = auth.uid()) with check (a_user = auth.uid());

-- Il destinatario può solo segnare il messaggio come letto, non cambiarne il contenuto
create or replace function public.messaggi_solo_lettura()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.da_user is distinct from old.da_user or new.a_user is distinct from old.a_user
     or new.testo is distinct from old.testo or new.created_at is distinct from old.created_at) then
    raise exception 'Di un messaggio si può cambiare solo lo stato di lettura';
  end if;
  return new;
end $$;
drop trigger if exists messaggi_ro on public.messaggi;
create trigger messaggi_ro before update on public.messaggi for each row execute function public.messaggi_solo_lettura();

-- Nuovo messaggio → notifica al destinatario
create or replace function public.notifiche_messaggio()
returns trigger language plpgsql security definer set search_path = public as $$
declare chi text;
begin
  select nome into chi from public.team_members where id = new.da_user;
  insert into public.notifiche (user_id, tipo, titolo, testo, rif_tipo, rif_id)
  select new.a_user, 'messaggio', 'Nuovo messaggio da ' || coalesce(chi, 'un collega'), left(new.testo, 160), 'messaggio', null;
  return new;
end $$;
revoke all on function public.notifiche_messaggio() from public, anon, authenticated;
drop trigger if exists messaggi_notifica on public.messaggi;
create trigger messaggi_notifica after insert on public.messaggi for each row execute function public.notifiche_messaggio();

------------------------------------------------------------------------
-- Tempo reale
------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.bacheca;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.messaggi;
exception when duplicate_object then null; when undefined_object then null; end $$;

comment on table public.bacheca is 'Bacheca delle comunicazioni del team Flowline.';
comment on table public.messaggi is 'Messaggi personali tra collaboratori Flowline.';
