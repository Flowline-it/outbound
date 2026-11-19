-- FlowLine Suite: Marketing › Notizie (le notizie trovate dal flusso n8n «Flowline Notizie»).
-- Da eseguire una volta nel SQL Editor del progetto Supabase "Lead Flowline". Si può rieseguire senza danni.
-- Richiede la migrazione 20261104100000_team_calendario_notifiche.sql (team_is_member).
--
-- La tabella public.notizie esiste già (la scrive il flusso n8n ogni giorno alle 7, solo notizie con rilevanza 3-5).
-- Qui si fa soltanto una cosa: la squadra può LEGGERLA dalla Suite (sola lettura, nessuna scrittura).
-- Il flusso n8n si collega direttamente al database e non è toccato dalle regole di accesso.

-- se per qualche motivo la tabella non c'è ancora, la crea con le colonne che il flusso usa
create table if not exists public.notizie (
  id            bigint generated always as identity primary key,
  trovata_il    timestamptz not null default now(),
  data_notizia  date,
  fonte         text,
  titolo        text not null,
  link          text not null unique,
  estratto      text,
  sintesi       text,
  rilevanza     smallint not null default 0
);

create index if not exists notizie_trovata_il_idx on public.notizie (trovata_il desc);

alter table public.notizie enable row level security;
drop policy if exists notizie_select on public.notizie;
create policy notizie_select on public.notizie for select to authenticated using (public.team_is_member());
grant select on public.notizie to authenticated;
