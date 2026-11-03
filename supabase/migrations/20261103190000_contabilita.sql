-- Contabilità: conti e movimenti, al posto della sezione "Contabilità" di Notion.
-- Si consulta e si modifica dall'area "Contabilità" della FlowLine Suite.
-- Dati economici dell'azienda: nessun accesso con la chiave pubblica (anon); leggono e scrivono
-- solo gli indirizzi presenti in newsletter_editors (stesso accesso di Newsletter e Richieste).

create table if not exists public.conti (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  nome        text not null,
  tipo        text not null default 'socio' check (tipo in ('azienda','socio')),
  apertura    numeric(12,2) not null default 0,   -- saldo iniziale: il saldo attuale = apertura + entrate - uscite
  ordine      int not null default 0
);

comment on table public.conti is
  'Conti della contabilità interna (conto aziendale e conti dei soci). Il saldo non è salvato: si calcola dai movimenti.';

create table if not exists public.movimenti (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  data        date,
  descrizione text not null,
  importo     numeric(12,2) not null check (importo > 0),
  tipo        text not null check (tipo in ('in','out','move')),   -- entrata, uscita, trasferimento tra conti
  da_conto    bigint references public.conti(id) on delete restrict,
  a_conto     bigint references public.conti(id) on delete restrict,
  categoria   text,
  stato       text not null default 'completato' check (stato in ('completato','in_corso','in_sospeso')),
  riferimento text,
  note        text,
  constraint movimenti_conti_coerenti check (
       (tipo = 'in'   and a_conto  is not null)
    or (tipo = 'out'  and da_conto is not null)
    or (tipo = 'move' and da_conto is not null and a_conto is not null and da_conto <> a_conto)
  )
);

comment on table public.movimenti is
  'Movimenti della contabilità interna. in = soldi che arrivano dall''esterno su a_conto; out = pagamento da da_conto (a_conto opzionale: socio che riceve una quota o un rimborso); move = spostamento tra due conti, non conta come entrata né uscita.';

create index if not exists movimenti_data_idx  on public.movimenti (data desc nulls last);
create index if not exists movimenti_da_idx    on public.movimenti (da_conto);
create index if not exists movimenti_a_idx     on public.movimenti (a_conto);

alter table public.conti     enable row level security;
alter table public.movimenti enable row level security;
revoke all on public.conti     from anon;
revoke all on public.movimenti from anon;

drop policy if exists "redazione: conti" on public.conti;
create policy "redazione: conti" on public.conti
  for all to authenticated
  using (public.newsletter_is_editor())
  with check (public.newsletter_is_editor());

drop policy if exists "redazione: movimenti" on public.movimenti;
create policy "redazione: movimenti" on public.movimenti
  for all to authenticated
  using (public.newsletter_is_editor())
  with check (public.newsletter_is_editor());

create or replace function public.movimenti_touch()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists movimenti_touch on public.movimenti;
create trigger movimenti_touch before update on public.movimenti
  for each row execute function public.movimenti_touch();
