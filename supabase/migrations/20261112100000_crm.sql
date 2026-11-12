-- FlowLine Suite: CRM (al posto di Notion › Flowline - Dashboard › CRM).
-- Richiede 20261104100000_team_calendario_notifiche.sql (team_members, team_is_member) e
-- 20261107100000_progetti_attivita.sql (progetti).
-- Da eseguire una volta nel SQL Editor del progetto Supabase "Lead Flowline". Si può rieseguire senza danni.
--
-- Come è pensato:
--  * crm_aziende: una riga per azienda (cliente, trattativa o contatto), con lo stato del rapporto.
--  * crm_referenti: le persone delle aziende. Una persona può stare in più aziende (aziende bigint[]).
--  * crm_preventivi, crm_incontri, crm_documenti: legati a una o più aziende (aziende bigint[]).
--  * crm_elenco: elenchi di aziende da valutare (es. «Veneto Orientale»); da qui si portano nel CRM.
--  * progetti.azienda_id: il progetto della Suite punta all'azienda cliente.
--  * Tutta la squadra vede e modifica tutto, come Progetti e Calendario.
--
-- I dati di Notion si caricano a parte con il file crm_import_notion.sql (non sta nel repository: contiene
-- nomi, telefoni ed email dei clienti).

------------------------------------------------------------------------
-- Aziende
------------------------------------------------------------------------
create table if not exists public.crm_aziende (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  nome               text not null check (length(trim(nome)) between 1 and 300),
  stato              text not null default 'da_contattare' check (stato in (
                       'da_contattare','contattato','programmato',        -- da sviluppare
                       'trattativa','preventivo',                         -- trattative
                       'progetto','assistenza','concluso',                -- clienti
                       'rete',                                            -- contatto acquisito (partner, rete)
                       'negativo')),
  settore            text,
  provenienza        text,
  email              text,
  telefono           text,
  sito               text,
  citta              text,
  primo_contatto_il  date,
  primo_contatto     text,            -- come è nato il contatto, cosa ha chiesto
  fatturazione       text,            -- ragione sociale, indirizzo, P. IVA, codice destinatario
  note               text,
  segue              uuid references public.team_members(id) on delete set null,   -- chi se ne occupa
  creato_da          uuid references public.team_members(id) on delete set null,
  notion_id          text
);
create unique index if not exists crm_aziende_notion_id_key on public.crm_aziende (notion_id) where notion_id is not null;
create index if not exists crm_aziende_stato_idx on public.crm_aziende (stato);

------------------------------------------------------------------------
-- Referenti (persone)
------------------------------------------------------------------------
create table if not exists public.crm_referenti (
  id               bigint generated always as identity primary key,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  aziende          bigint[] not null default '{}',
  nome             text not null check (length(trim(nome)) between 1 and 200),
  ruolo            text,
  email            text,
  telefono         text,
  linkedin         text,
  canale           text[] not null default '{}',     -- come preferisce essere contattato: {telefono,email}
  ultimo_contatto  date,
  note             text,
  creato_da        uuid references public.team_members(id) on delete set null,
  notion_id        text
);
create unique index if not exists crm_referenti_notion_id_key on public.crm_referenti (notion_id) where notion_id is not null;
create index if not exists crm_referenti_aziende_idx on public.crm_referenti using gin (aziende);

------------------------------------------------------------------------
-- Preventivi
------------------------------------------------------------------------
create table if not exists public.crm_preventivi (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  aziende      bigint[] not null default '{}',
  nome         text not null check (length(trim(nome)) between 1 and 300),
  stato        text not null default 'da_preparare' check (stato in ('da_preparare','in_lavorazione','inviato','accettato','rifiutato')),
  importo      numeric(12,2),
  inviato_il   date,
  documento    text,             -- link al documento (Drive, Canva…)
  note         text,
  creato_da    uuid references public.team_members(id) on delete set null,
  notion_id    text
);
create unique index if not exists crm_preventivi_notion_id_key on public.crm_preventivi (notion_id) where notion_id is not null;
create index if not exists crm_preventivi_aziende_idx on public.crm_preventivi using gin (aziende);

------------------------------------------------------------------------
-- Incontri e riunioni
------------------------------------------------------------------------
create table if not exists public.crm_incontri (
  id               bigint generated always as identity primary key,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  aziende          bigint[] not null default '{}',
  titolo           text not null check (length(trim(titolo)) between 1 and 300),
  data             timestamptz,
  persone          uuid[] not null default '{}',      -- chi c'era di Flowline (team_members.id)
  referenti        bigint[] not null default '{}',    -- chi c'era dell'azienda (crm_referenti.id)
  verbale          text,
  prossimi_passi   text,
  creato_da        uuid references public.team_members(id) on delete set null,
  notion_id        text
);
create unique index if not exists crm_incontri_notion_id_key on public.crm_incontri (notion_id) where notion_id is not null;
create index if not exists crm_incontri_aziende_idx on public.crm_incontri using gin (aziende);

------------------------------------------------------------------------
-- Documenti (link a Drive e simili)
------------------------------------------------------------------------
create table if not exists public.crm_documenti (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  aziende      bigint[] not null default '{}',
  progetto_id  bigint references public.progetti(id) on delete set null,
  nome         text not null check (length(trim(nome)) between 1 and 300),
  url          text,
  data         date,
  creato_da    uuid references public.team_members(id) on delete set null,
  notion_id    text
);
create unique index if not exists crm_documenti_notion_id_key on public.crm_documenti (notion_id) where notion_id is not null;
create index if not exists crm_documenti_aziende_idx on public.crm_documenti using gin (aziende);

------------------------------------------------------------------------
-- Elenchi di aziende da valutare
------------------------------------------------------------------------
create table if not exists public.crm_elenco (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  lista              text not null default 'Elenco',
  posizione          integer,
  nome               text not null check (length(trim(nome)) between 1 and 400),
  citta              text,
  descrizione        text,
  dipendenti         integer,
  valore_produzione  numeric(14,3),     -- come nella fonte (Notion)
  utile              numeric(14,3),
  azienda_id         bigint references public.crm_aziende(id) on delete set null,   -- portata nel CRM
  scartata           boolean not null default false,
  creato_da          uuid references public.team_members(id) on delete set null,
  notion_id          text
);
create unique index if not exists crm_elenco_notion_id_key on public.crm_elenco (notion_id) where notion_id is not null;
create index if not exists crm_elenco_lista_idx on public.crm_elenco (lista);

------------------------------------------------------------------------
-- Progetto → azienda cliente
------------------------------------------------------------------------
alter table public.progetti add column if not exists azienda_id bigint;
do $$ begin
  alter table public.progetti add constraint progetti_azienda_fk foreign key (azienda_id) references public.crm_aziende(id) on delete set null;
exception when duplicate_object then null; end $$;
create index if not exists progetti_azienda_idx on public.progetti (azienda_id);

------------------------------------------------------------------------
-- Regole: tutta la squadra, niente accesso anonimo
------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['crm_aziende','crm_referenti','crm_preventivi','crm_incontri','crm_documenti','crm_elenco'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.team_is_member()) with check (public.team_is_member())', t || '_all', t);
  end loop;
end $$;

------------------------------------------------------------------------
-- Data di modifica e autore
------------------------------------------------------------------------
create or replace function public.crm_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' and new.creato_da is null then
    new.creato_da := (select id from public.team_members where id = auth.uid());
  end if;
  return new;
end $$;
revoke all on function public.crm_before_write() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['crm_aziende','crm_referenti','crm_preventivi','crm_incontri','crm_documenti','crm_elenco'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_bw', t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.crm_before_write()', t || '_bw', t);
  end loop;
end $$;

------------------------------------------------------------------------
-- Aggiornamenti in tempo reale
------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['crm_aziende','crm_referenti','crm_preventivi','crm_incontri','crm_documenti','crm_elenco'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_object then null; end;
  end loop;
end $$;
