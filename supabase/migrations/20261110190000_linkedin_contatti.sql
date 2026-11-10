-- FlowLine Suite: Outbound › LinkedIn (al posto di Notion › «Ricerca clienti LinkedIn»).
-- Richiede la migrazione 20261104100000_team_calendario_notifiche.sql (team_members, team_is_member).
-- Da eseguire una volta nel SQL Editor del progetto Supabase "Lead Flowline". Si può rieseguire senza danni.
--
-- Come è pensato:
--  * linkedin_contatti: una riga per persona da contattare su LinkedIn, con gli stessi campi della tabella di Notion
--    (nome, azienda, ruolo, di chi è, stato, profilo, e-mail, data invito, data messaggio, testo inviato, risposta, descrizione)
--    più un campo «note» libero.
--  * Quattro stati, come in Notion: da_contattare, contattato, risposto, esito_negativo.
--  * Tutta la squadra vede e modifica tutto.
--  * notion_url serve solo all'importazione dei dati da Notion: chi c'è già non viene duplicato.
--
-- I dati di Notion si caricano con un file a parte (linkedin_import_notion.sql), che non sta nel repository.

create table if not exists public.linkedin_contatti (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  nome          text not null default '',
  azienda       text not null default '',
  ruolo         text not null default '',
  competenza_di uuid references public.team_members(id) on delete set null,   -- chi segue il contatto
  stato         text not null default 'da_contattare' check (stato in ('da_contattare','contattato','risposto','esito_negativo')),
  url_profilo   text,
  email         text,
  invito_il     date,                 -- quando è stata inviata la richiesta di collegamento
  messaggio_il  date,                 -- quando è stato inviato il messaggio
  messaggio     text,                 -- testo del messaggio inviato
  risposta      text,                 -- risposta ricevuta
  descrizione   text,                 -- che cosa fa l'azienda
  note          text,
  creato_da     uuid references public.team_members(id) on delete set null,
  notion_url    text
);
create unique index if not exists linkedin_contatti_notion_key on public.linkedin_contatti (notion_url) where notion_url is not null;
create index if not exists linkedin_contatti_stato_idx on public.linkedin_contatti (stato);
create index if not exists linkedin_contatti_competenza_idx on public.linkedin_contatti (competenza_di);
create index if not exists linkedin_contatti_created_idx on public.linkedin_contatti (created_at desc);

alter table public.linkedin_contatti enable row level security;
revoke all on public.linkedin_contatti from anon;

drop policy if exists linkedin_contatti_all on public.linkedin_contatti;
create policy linkedin_contatti_all on public.linkedin_contatti for all to authenticated
  using (public.team_is_member()) with check (public.team_is_member());

create or replace function public.linkedin_contatti_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.creato_da is null then new.creato_da := auth.uid(); end if;
  new.nome    := coalesce(trim(new.nome), '');
  new.azienda := coalesce(trim(new.azienda), '');
  new.ruolo   := coalesce(trim(new.ruolo), '');
  return new;
end $$;
revoke all on function public.linkedin_contatti_before_write() from public, anon, authenticated;
drop trigger if exists linkedin_contatti_bw on public.linkedin_contatti;
create trigger linkedin_contatti_bw before insert or update on public.linkedin_contatti
  for each row execute function public.linkedin_contatti_before_write();

-- aggiornamenti in tempo reale (due persone aperte sulla stessa lista si vedono le modifiche)
do $$ begin
  alter publication supabase_realtime add table public.linkedin_contatti;
exception when duplicate_object then null; when undefined_object then null; end $$;
