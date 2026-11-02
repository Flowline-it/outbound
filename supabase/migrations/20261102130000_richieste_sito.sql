-- Richieste di consulenza dal form di flowline.it.
-- Prima stavano nella tabella "consultations" del progetto FLOWLINE JOURNAL; ora stanno qui,
-- accanto a Outbound e Newsletter, e si consultano dall'area "Richieste" della FlowLine Suite.

create table if not exists public.richieste_sito (
  id                    bigint generated always as identity primary key,
  created_at            timestamptz not null default now(),
  nome_cognome          text not null,
  email                 text not null,
  nome_azienda          text,
  telefono              text,
  descrizione_progetto  text,
  come_hai_sentito      text,
  ruolo_azienda         text,          -- non più chiesto dal form, resta per le richieste vecchie
  servizio_interessato  text,          -- idem
  stato                 text not null default 'nuova'
                        check (stato in ('nuova','contattata','in_trattativa','cliente','archiviata')),
  note                  text,
  origine               text not null default 'sito',   -- 'sito' oppure 'journal' per quelle importate
  updated_at            timestamptz not null default now()
);

comment on table public.richieste_sito is
  'Richieste di consulenza dal form di flowline.it. Il sito scrive solo tramite richiesta_sito_invia(); leggono e modificano solo gli indirizzi in newsletter_editors.';

create index if not exists richieste_sito_created_idx on public.richieste_sito (created_at desc);
create index if not exists richieste_sito_stato_idx   on public.richieste_sito (stato);

alter table public.richieste_sito enable row level security;
revoke all on public.richieste_sito from anon;

drop policy if exists "redazione: richieste" on public.richieste_sito;
create policy "redazione: richieste" on public.richieste_sito
  for all to authenticated
  using (public.newsletter_is_editor())
  with check (public.newsletter_is_editor());

create or replace function public.richieste_sito_touch()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists richieste_sito_touch on public.richieste_sito;
create trigger richieste_sito_touch before update on public.richieste_sito
  for each row execute function public.richieste_sito_touch();

-- Unico punto di scrittura per il sito (chiave pubblicabile). Controlla i campi,
-- ignora i bot (campo nascosto p_website) e i doppi invii della stessa email entro 2 minuti.
create or replace function public.richiesta_sito_invia(
  p_nome_cognome text,
  p_email        text,
  p_nome_azienda text,
  p_telefono     text default null,
  p_descrizione  text default null,
  p_fonte        text default null,
  p_website      text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_nome  text := left(trim(coalesce(p_nome_cognome, '')), 200);
  v_az    text := left(trim(coalesce(p_nome_azienda, '')), 200);
begin
  if coalesce(p_website, '') <> '' then return 'ok'; end if;
  if v_nome = '' then raise exception 'nome mancante' using errcode = '22023'; end if;
  if v_az = '' then raise exception 'azienda mancante' using errcode = '22023'; end if;
  if length(v_email) > 200 or v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'email non valida' using errcode = '22023';
  end if;
  if exists (select 1 from public.richieste_sito
             where email = v_email and created_at > now() - interval '2 minutes') then
    return 'ok';
  end if;
  insert into public.richieste_sito (nome_cognome, email, nome_azienda, telefono, descrizione_progetto, come_hai_sentito)
  values (v_nome, v_email, v_az,
          nullif(left(trim(coalesce(p_telefono, '')), 40), ''),
          nullif(left(trim(coalesce(p_descrizione, '')), 4000), ''),
          nullif(left(trim(coalesce(p_fonte, '')), 80), ''));
  return 'ok';
end $$;

revoke all on function public.richiesta_sito_invia(text,text,text,text,text,text,text) from public;
grant execute on function public.richiesta_sito_invia(text,text,text,text,text,text,text) to anon, authenticated;
