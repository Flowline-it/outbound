-- FlowLine Suite: squadra (4 account personali), calendario condiviso e notifiche.
-- Da eseguire una volta nel progetto Supabase "Lead Flowline" (SQL Editor). Si può rieseguire senza danni.
--
-- Come è pensato:
--  * team_members: una riga per persona, collegata al suo account di accesso (Authentication → Users).
--    Tutti hanno gli stessi permessi, nessun ruolo di amministratore.
--  * eventi: calendario condiviso. Un evento è «azienda» (call e appuntamenti di Flowline, sincronizzati
--    con Google Calendar di info@flowline.it) oppure «personale» (impegno di una sola persona, mai inviato a Google).
--  * evento_partecipanti: chi partecipa a ciascun evento.
--  * notifiche: avvisi per persona, generati dal database quando qualcuno viene aggiunto, o un evento cambia o si sposta.
--    Le colonne rif_tipo/rif_id e il tipo libero servono per i futuri task e progetti senza rifare la struttura.
--  * Sincronizzazione Google: due flussi n8n. Google → suite scrive direttamente nelle tabelle;
--    suite → Google parte da un webhook chiamato dal database (stesso schema di Ricerca lead).
--
-- Dopo la migrazione, per ogni persona (dopo averne creato l'utente in Authentication → Users):
--   select public.team_aggiungi('email-di-login@esempio.it', 'Giuseppe', '#F59E0B');

------------------------------------------------------------------------
-- Squadra
------------------------------------------------------------------------
create table if not exists public.team_members (
  id          uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  nome        text not null,
  email       text not null,
  colore      text not null default '#6B7280',
  attivo      boolean not null default true
);
-- indirizzo con cui la persona compare su Google Calendar, se diverso da quello di accesso
alter table public.team_members add column if not exists email_google text;
create unique index if not exists team_members_email_key on public.team_members (lower(email));
alter table public.team_members enable row level security;
revoke all on public.team_members from anon;

create or replace function public.team_is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_members t where t.id = auth.uid() and t.attivo)
$$;
revoke all on function public.team_is_member() from public, anon;
grant execute on function public.team_is_member() to authenticated;

drop policy if exists team_members_select on public.team_members;
create policy team_members_select on public.team_members for select to authenticated using (public.team_is_member());
-- ognuno può cambiare solo il proprio nome e il proprio colore
drop policy if exists team_members_update on public.team_members;
create policy team_members_update on public.team_members for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Aggiunge una persona alla squadra a partire dal suo utente di accesso. Si lancia dal SQL Editor.
create or replace function public.team_aggiungi(p_email text, p_nome text, p_colore text default '#6B7280')
returns text language plpgsql security definer set search_path = public, auth as $$
declare u uuid;
begin
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then
    raise exception 'Nessun utente con email % in Authentication → Users: crealo prima.', p_email;
  end if;
  insert into public.team_members (id, nome, email, colore)
  values (u, trim(p_nome), lower(trim(p_email)), coalesce(nullif(trim(p_colore), ''), '#6B7280'))
  on conflict (id) do update set nome = excluded.nome, email = excluded.email, colore = excluded.colore, attivo = true;
  return 'ok: ' || p_nome;
end $$;
revoke all on function public.team_aggiungi(text, text, text) from public, anon, authenticated;

-- Chi è nella squadra vede anche le altre aree (Newsletter, Ricerca lead, Richieste, Contabilità):
-- quelle aree controllano newsletter_is_editor() tramite l'elenco newsletter_editors, quindi lo teniamo allineato.
create or replace function public.team_members_sync_editors()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into public.newsletter_editors (email)
    select new.email where not exists (select 1 from public.newsletter_editors e where lower(e.email) = lower(new.email));
  exception when others then
    raise warning 'team_members → newsletter_editors non allineato: %', sqlerrm;
  end;
  return new;
end $$;
revoke all on function public.team_members_sync_editors() from public, anon, authenticated;
drop trigger if exists team_members_ai on public.team_members;
create trigger team_members_ai after insert on public.team_members for each row execute function public.team_members_sync_editors();

------------------------------------------------------------------------
-- Eventi
------------------------------------------------------------------------
create table if not exists public.eventi (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  titolo          text not null,
  descrizione     text,
  luogo           text,
  link_call       text,
  cliente         text,
  inizio          timestamptz not null,
  fine            timestamptz not null,
  tutto_il_giorno boolean not null default false,
  tipo            text not null default 'call' check (tipo in ('call','appuntamento','impegno','altro')),
  calendario      text not null default 'azienda' check (calendario in ('azienda','personale')),
  stato           text not null default 'confermato' check (stato in ('confermato','annullato')),
  creato_da       uuid references public.team_members(id) on delete set null,
  origine         text not null default 'suite' check (origine in ('suite','google')),
  google_id       text,
  google_link     text,
  ospiti          text[] not null default '{}',
  sync_da_inviare boolean not null default false,
  progetto_id     bigint,                      -- riservato ai futuri progetti
  check (fine >= inizio)
);
create unique index if not exists eventi_google_id_key on public.eventi (google_id) where google_id is not null;
create index if not exists eventi_inizio_idx on public.eventi (inizio);
alter table public.eventi enable row level security;
revoke all on public.eventi from anon;

create table if not exists public.evento_partecipanti (
  evento_id bigint not null references public.eventi(id) on delete cascade,
  user_id   uuid not null references public.team_members(id) on delete cascade,
  primary key (evento_id, user_id)
);
create index if not exists evento_partecipanti_user_idx on public.evento_partecipanti (user_id);
alter table public.evento_partecipanti enable row level security;
revoke all on public.evento_partecipanti from anon;

-- Tutti i membri hanno gli stessi permessi: vedono e gestiscono tutti gli eventi.
drop policy if exists eventi_all on public.eventi;
create policy eventi_all on public.eventi for all to authenticated
  using (public.team_is_member()) with check (public.team_is_member());
drop policy if exists evento_partecipanti_all on public.evento_partecipanti;
create policy evento_partecipanti_all on public.evento_partecipanti for all to authenticated
  using (public.team_is_member()) with check (public.team_is_member());

------------------------------------------------------------------------
-- Notifiche
------------------------------------------------------------------------
create table if not exists public.notifiche (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  user_id      uuid not null references public.team_members(id) on delete cascade,
  tipo         text not null,                   -- evento_aggiunto, evento_spostato, evento_modificato, evento_annullato, in futuro task_assegnato…
  titolo       text not null,
  testo        text not null,
  evento_id    bigint references public.eventi(id) on delete set null,
  rif_tipo     text,                            -- riferimento generico (futuro: 'task', 'progetto')
  rif_id       bigint,
  letta_il     timestamptz,
  email_stato  text not null default 'non_richiesta' check (email_stato in ('non_richiesta','da_inviare','inviata','errore'))
);
create index if not exists notifiche_user_idx on public.notifiche (user_id, created_at desc);
alter table public.notifiche enable row level security;
revoke all on public.notifiche from anon;

-- Ognuno vede e gestisce solo le proprie notifiche. Le notifiche le crea solo il database.
drop policy if exists notifiche_select on public.notifiche;
create policy notifiche_select on public.notifiche for select to authenticated using (user_id = auth.uid());
drop policy if exists notifiche_update on public.notifiche;
create policy notifiche_update on public.notifiche for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists notifiche_delete on public.notifiche;
create policy notifiche_delete on public.notifiche for delete to authenticated using (user_id = auth.uid());

------------------------------------------------------------------------
-- Funzioni: testo e creazione delle notifiche
------------------------------------------------------------------------
create or replace function public.evento_quando(p_inizio timestamptz, p_tutto boolean)
returns text language sql stable set search_path = public as $$
  select case when p_tutto
    then 'il giorno ' || to_char(p_inizio at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' (tutto il giorno)'
    else 'il giorno ' || to_char(p_inizio at time zone 'Europe/Rome', 'DD/MM/YYYY') || ' alle ore ' || to_char(p_inizio at time zone 'Europe/Rome', 'HH24:MI')
  end
$$;

create or replace function public.evento_nome(e public.eventi)
returns text language sql stable set search_path = public as $$
  select coalesce(nullif(trim(e.cliente), ''), e.titolo)
$$;

-- Un partecipante viene aggiunto a un evento → avviso a quella persona (non a chi ha fatto la modifica).
create or replace function public.notifiche_partecipante_aggiunto()
returns trigger language plpgsql security definer set search_path = public as $$
declare e public.eventi; t text; x text;
begin
  select * into e from public.eventi where id = new.evento_id;
  if e.id is null or e.stato = 'annullato' then return new; end if;
  if new.user_id is not distinct from auth.uid() then return new; end if;   -- ti sei aggiunto da solo
  if e.fine < now() then return new; end if;                                -- evento già passato
  if e.tipo = 'call' then
    t := 'Nuova call'; x := 'Sei stato aggiunto a una nuova call: ';
  elsif e.tipo = 'appuntamento' then
    t := 'Nuovo appuntamento'; x := 'Ti è stato assegnato un appuntamento: ';
  else
    t := 'Nuovo impegno'; x := 'Ti è stato assegnato un impegno: ';
  end if;
  insert into public.notifiche (user_id, tipo, titolo, testo, evento_id)
  values (new.user_id, 'evento_aggiunto', t, x || public.evento_nome(e) || ', ' || public.evento_quando(e.inizio, e.tutto_il_giorno) || '.', e.id);
  return new;
end $$;
revoke all on function public.notifiche_partecipante_aggiunto() from public, anon, authenticated;
drop trigger if exists evento_partecipanti_notifica on public.evento_partecipanti;
create trigger evento_partecipanti_notifica after insert on public.evento_partecipanti
  for each row execute function public.notifiche_partecipante_aggiunto();

-- Un evento viene spostato, modificato o annullato → avviso a tutti i partecipanti tranne chi l'ha cambiato.
create or replace function public.notifiche_evento_cambiato()
returns trigger language plpgsql security definer set search_path = public as $$
declare tp text; ti text; tx text; nome text;
begin
  if new.fine < now() and new.inizio < now() then return new; end if;
  nome := public.evento_nome(new);
  if new.stato = 'annullato' and old.stato <> 'annullato' then
    tp := 'evento_annullato'; ti := 'Evento annullato';
    tx := 'È stato annullato: ' || nome || ', previsto ' || public.evento_quando(old.inizio, old.tutto_il_giorno) || '.';
  elsif new.stato = 'annullato' then
    return new;
  elsif new.inizio is distinct from old.inizio or new.fine is distinct from old.fine or new.tutto_il_giorno is distinct from old.tutto_il_giorno then
    tp := 'evento_spostato'; ti := 'Evento spostato';
    tx := 'È stato spostato: ' || nome || ', ora ' || public.evento_quando(new.inizio, new.tutto_il_giorno) || ' (era ' || public.evento_quando(old.inizio, old.tutto_il_giorno) || ').';
  elsif new.titolo is distinct from old.titolo or new.luogo is distinct from old.luogo or new.link_call is distinct from old.link_call
     or new.cliente is distinct from old.cliente or new.tipo is distinct from old.tipo then
    tp := 'evento_modificato'; ti := 'Evento modificato';
    tx := 'È stato modificato: ' || nome || ', ' || public.evento_quando(new.inizio, new.tutto_il_giorno) || '.';
  else
    return new;
  end if;
  insert into public.notifiche (user_id, tipo, titolo, testo, evento_id)
  select p.user_id, tp, ti, tx, new.id
  from public.evento_partecipanti p
  where p.evento_id = new.id and p.user_id is distinct from auth.uid();
  return new;
end $$;
revoke all on function public.notifiche_evento_cambiato() from public, anon, authenticated;
drop trigger if exists eventi_notifica on public.eventi;
create trigger eventi_notifica after update on public.eventi
  for each row execute function public.notifiche_evento_cambiato();

------------------------------------------------------------------------
-- Eventi: data di modifica, autore e segnale per la sincronizzazione con Google
------------------------------------------------------------------------
create or replace function public.eventi_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.creato_da is null then new.creato_da := auth.uid(); end if;
  -- solo le modifiche fatte da una persona nella suite (non quelle di n8n) vanno spinte su Google;
  -- gli impegni personali non vanno mai sul calendario aziendale
  if new.calendario <> 'azienda' then
    new.sync_da_inviare := false;
  elsif auth.uid() is not null then
    new.sync_da_inviare := true;
  end if;
  return new;
end $$;
revoke all on function public.eventi_before_write() from public, anon, authenticated;
drop trigger if exists eventi_bw on public.eventi;
create trigger eventi_bw before insert or update on public.eventi for each row execute function public.eventi_before_write();

-- cambiare i partecipanti dalla suite = evento da riallineare su Google
create or replace function public.evento_partecipanti_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    update public.eventi set updated_at = now()
    where id = coalesce(new.evento_id, old.evento_id) and calendario = 'azienda';
  end if;
  return coalesce(new, old);
end $$;
revoke all on function public.evento_partecipanti_touch() from public, anon, authenticated;
drop trigger if exists evento_partecipanti_touch_t on public.evento_partecipanti;
create trigger evento_partecipanti_touch_t after insert or delete on public.evento_partecipanti
  for each row execute function public.evento_partecipanti_touch();

-- Chiama il flusso n8n «Calendario: suite → Google». Parametri nel Vault (una volta sola):
--   select vault.create_secret('https://leo98.app.n8n.cloud/webhook/flowline-calendario', 'calendar_webhook_url');
--   select vault.create_secret('una-chiave-lunga-casuale', 'calendar_webhook_key');   -- la stessa controllata dal webhook n8n (header x-flowline-key)
-- Se mancano, non succede niente: l'evento resta «da inviare» e parte alla prima modifica successiva.
create or replace function public.eventi_notify_google()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare hook text; k text; payload jsonb;
begin
  select decrypted_secret into hook from vault.decrypted_secrets where name = 'calendar_webhook_url';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'calendar_webhook_key';
  if hook is null or k is null then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.google_id is null or old.calendario <> 'azienda' or auth.uid() is null then return old; end if;
    payload := jsonb_build_object('azione', 'elimina', 'google_id', old.google_id);
  else
    if not new.sync_da_inviare then return new; end if;
    -- raffica di modifiche: se l'evento è già in attesa da pochi secondi, n8n lo leggerà aggiornato, niente nuova chiamata
    if tg_op = 'UPDATE' and old.sync_da_inviare and old.updated_at > now() - interval '30 seconds' then return new; end if;
    payload := jsonb_build_object('azione', 'invia', 'evento_id', new.id);
  end if;
  perform net.http_post(url := hook, body := payload,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-flowline-key', k),
    timeout_milliseconds := 10000);
  return coalesce(new, old);
end $$;
revoke all on function public.eventi_notify_google() from public, anon, authenticated;
drop trigger if exists eventi_google_ai on public.eventi;
create trigger eventi_google_ai after insert or update on public.eventi for each row execute function public.eventi_notify_google();
drop trigger if exists eventi_google_ad on public.eventi;
create trigger eventi_google_ad after delete on public.eventi for each row execute function public.eventi_notify_google();

------------------------------------------------------------------------
-- Aggiornamento in tempo reale della campanella
------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.notifiche;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.eventi;
exception when duplicate_object then null; when undefined_object then null; end $$;

comment on table public.team_members is 'Le persone della suite (account di accesso). Tutti con gli stessi permessi.';
comment on table public.eventi is 'Calendario condiviso Flowline: eventi azienda (sincronizzati con Google Calendar) e impegni personali.';
comment on table public.notifiche is 'Notifiche per persona, create dal database. rif_tipo/rif_id per i futuri task e progetti.';
