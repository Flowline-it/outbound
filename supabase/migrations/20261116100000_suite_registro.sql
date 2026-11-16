-- FlowLine Suite: Registro (16 novembre 2026)
-- Un unico elenco di tutto quello che cambia nella Suite e di tutte le esecuzioni dei flussi n8n.
--  * Modifiche: un trigger su ogni tabella principale scrive chi ha fatto cosa (crea / modifica / elimina),
--    con i campi cambiati (prima → dopo). Chi = la persona collegata (auth.uid()); se manca è un flusso
--    o una funzione automatica. Un flusso può firmarsi con set_config('suite.flusso', 'Nome flusso', true).
--  * Esecuzioni: il flusso n8n «Suite: registro delle esecuzioni» legge ogni 15 minuti le esecuzioni dei
--    flussi della Suite e le passa a suite_registra_esecuzioni().
--  * Un flusso può anche scrivere una riga a mano con suite_registra({flusso, titolo, testo, area, esito, link}).
-- Il registro non blocca mai il salvataggio: se qualcosa va storto nel trigger, la modifica passa lo stesso.
-- Si può rieseguire.

create table if not exists public.suite_registro (
  id             bigint generated always as identity primary key,
  created_at     timestamptz not null default now(),
  chi            uuid references public.team_members(id) on delete set null,
  fonte          text not null default 'suite' check (fonte in ('suite','flusso','claude','sistema')),
  flusso         text,                 -- nome del flusso n8n (fonte flusso / claude)
  area           text not null,        -- progetti, crm, calendario, home, contabilita, password, linkedin, richieste, newsletter, flussi
  tabella        text,
  azione         text not null check (azione in ('crea','modifica','elimina','esecuzione','nota')),
  rif_id         text,
  titolo         text,                 -- che cosa: titolo dell'attività, nome dell'azienda…
  contesto       text,                 -- dove: progetto, azienda, cliente
  modifiche      jsonb not null default '{}'::jsonb,   -- {campo: [prima, dopo]}
  testo          text,
  esito          text not null default 'ok' check (esito in ('ok','errore','avviso','in_corso')),
  esecuzione_id  text,                 -- id dell'esecuzione n8n
  workflow_id    text,
  durata_ms      integer,
  link           text
);
create unique index if not exists suite_registro_esecuzione_key on public.suite_registro (esecuzione_id) where esecuzione_id is not null;
create index if not exists suite_registro_recenti_idx on public.suite_registro (created_at desc);
create index if not exists suite_registro_area_idx on public.suite_registro (area, created_at desc);
create index if not exists suite_registro_rif_idx on public.suite_registro (tabella, rif_id);

alter table public.suite_registro enable row level security;
drop policy if exists suite_registro_select on public.suite_registro;
create policy suite_registro_select on public.suite_registro for select to authenticated using (public.team_is_member());
-- nessuna policy di scrittura: scrivono solo i trigger e le funzioni qui sotto
revoke insert, update, delete on public.suite_registro from anon, authenticated;

------------------------------------------------------------------------
-- Trigger generico
------------------------------------------------------------------------
-- campi che non raccontano niente (tempi di sistema, contatori, dati tecnici)
create or replace function public.suite_registro_ignora() returns text[]
language sql immutable as $$
  select array['updated_at','created_at','fatto_il','sync_da_inviare','google_link','home_layout','riepilogo_inviato_il',
               'sent_count','failed_count','total','claimed_at','pw_cifrata','ha_password','updated_by','created_by','creato_da','notion_id','notion_url']
$$;

create or replace function public.suite_registro_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j jsonb; o jsonb; diff jsonb := '{}'::jsonb; k text; v_area text := tg_argv[0]; v_chi uuid; v_fonte text; v_flusso text;
  v_tit text; v_ctx text; v_az text; ign text[] := suite_registro_ignora(); nascondi boolean := tg_table_name = 'credenziali';
begin
  if coalesce(current_setting('suite.registro_off', true), '') = '1' then return null; end if;
  begin
    j := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
    if tg_op = 'UPDATE' then
      o := to_jsonb(old);
      for k in select jsonb_object_keys(j) loop
        continue when k = any (ign) or k = 'id';
        if (j->k) is distinct from (o->k) then
          diff := diff || jsonb_build_object(k, case when nascondi and k not in ('servizio','categoria','url')
            then jsonb_build_array(null, null)
            else jsonb_build_array(
              case when jsonb_typeof(o->k) = 'string' and length(o->>k) > 300 then to_jsonb(left(o->>k, 300) || '…') else o->k end,
              case when jsonb_typeof(j->k) = 'string' and length(j->>k) > 300 then to_jsonb(left(j->>k, 300) || '…') else j->k end) end);
        end if;
      end loop;
      if diff = '{}'::jsonb then return null; end if;     -- niente di interessante è cambiato
    end if;

    select t.id into v_chi from team_members t where t.id = auth.uid();
    v_flusso := nullif(current_setting('suite.flusso', true), '');
    v_fonte := case when v_chi is not null then 'suite'
                    when v_flusso ilike 'claude%' then 'claude'
                    when v_flusso is not null then 'flusso'
                    else 'sistema' end;

    v_tit := coalesce(nullif(j->>'titolo', ''), nullif(j->>'nome', ''), nullif(j->>'subject', ''), nullif(j->>'servizio', ''),
                      nullif(j->>'nome_azienda', ''), nullif(j->>'nome_cognome', ''), nullif(j->>'descrizione', ''),
                      nullif(j->>'azienda', ''), left(nullif(j->>'testo', ''), 80), '#' || (j->>'id'));
    v_tit := left(v_tit, 200);

    if tg_table_name = 'attivita' then
      select p.nome into v_ctx from progetti p where p.id = (j->>'progetto_id')::bigint;
    elsif tg_table_name = 'progetti' then
      v_ctx := nullif(j->>'cliente', '');
    elsif j ? 'aziende' and jsonb_typeof(j->'aziende') = 'array' and jsonb_array_length(j->'aziende') > 0 then
      select a.nome into v_ctx from crm_aziende a where a.id = (j->'aziende'->>0)::bigint;
    elsif tg_table_name = 'eventi' then
      v_ctx := nullif(j->>'cliente', '');
    elsif tg_table_name = 'linkedin_contatti' then
      v_ctx := case when nullif(j->>'azienda', '') is not null and j->>'azienda' <> v_tit then j->>'azienda' end;
    end if;

    insert into suite_registro (chi, fonte, flusso, area, tabella, azione, rif_id, titolo, contesto, modifiche)
    values (v_chi, v_fonte, v_flusso, v_area, tg_table_name,
            case tg_op when 'INSERT' then 'crea' when 'UPDATE' then 'modifica' else 'elimina' end,
            j->>'id', v_tit, left(v_ctx, 200), diff);
  exception when others then
    raise warning 'suite_registro: % (%)', sqlerrm, tg_table_name;
  end;
  return null;
end $$;
revoke all on function public.suite_registro_trg() from public, anon, authenticated;

-- aggancio il trigger alle tabelle che esistono (area come argomento)
do $$
declare r record;
begin
  for r in select * from (values
      ('progetti','progetti'), ('attivita','progetti'),
      ('crm_aziende','crm'), ('crm_referenti','crm'), ('crm_preventivi','crm'), ('crm_incontri','crm'), ('crm_documenti','crm'), ('crm_elenco','crm'),
      ('eventi','calendario'), ('bacheca','home'),
      ('movimenti','contabilita'), ('conti','contabilita'), ('credenziali','password'),
      ('linkedin_contatti','linkedin'), ('richieste_sito','richieste'), ('newsletter_campaigns','newsletter')
    ) v(t, area)
  loop
    if to_regclass('public.' || r.t) is not null then
      execute format('drop trigger if exists suite_registro on public.%I', r.t);
      execute format('create trigger suite_registro after insert or update or delete on public.%I for each row execute function public.suite_registro_trg(%L)', r.t, r.area);
    end if;
  end loop;
end $$;

------------------------------------------------------------------------
-- Funzioni per i flussi n8n (credenziale Postgres «Lead Flowline»)
------------------------------------------------------------------------
-- una riga scritta da un flusso: {"flusso","titolo","testo","area","esito","link","rif_id","contesto"}
create or replace function public.suite_registra(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare nid bigint;
begin
  insert into suite_registro (fonte, flusso, area, azione, titolo, testo, contesto, esito, link, rif_id)
  values (case when p->>'flusso' ilike 'claude%' then 'claude' else 'flusso' end,
          left(nullif(p->>'flusso', ''), 120), coalesce(nullif(p->>'area', ''), 'flussi'), 'nota',
          left(coalesce(nullif(p->>'titolo', ''), 'Aggiornamento'), 300), left(p->>'testo', 4000), left(p->>'contesto', 200),
          case when p->>'esito' in ('ok','errore','avviso','in_corso') then p->>'esito' else 'ok' end,
          left(p->>'link', 1000), left(p->>'rif_id', 100))
  returning id into nid;
  return nid;
end $$;

-- esecuzioni: [{"id","workflow_id","flusso","stato","inizio","fine","modo"}]; ripetibile (aggiorna le «in corso»)
create or replace function public.suite_registra_esecuzioni(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; n_new int := 0; n_upd int := 0; v_esito text; v_ini timestamptz; v_fin timestamptz; base text := coalesce(nullif(p->>'base_url', ''), 'https://leo98.app.n8n.cloud');
begin
  for x in select * from jsonb_array_elements(coalesce(p->'esecuzioni', '[]'::jsonb)) loop
    continue when nullif(x->>'id', '') is null;
    v_esito := case when x->>'stato' in ('success') then 'ok'
                    when x->>'stato' in ('error','crashed','failed') then 'errore'
                    when x->>'stato' in ('canceled','cancelled') then 'avviso'
                    else 'in_corso' end;
    v_ini := nullif(x->>'inizio', '')::timestamptz;
    v_fin := nullif(x->>'fine', '')::timestamptz;
    insert into suite_registro (created_at, fonte, flusso, area, azione, titolo, esito, esecuzione_id, workflow_id, durata_ms, link, testo)
    values (coalesce(v_ini, now()), 'flusso', left(coalesce(nullif(x->>'flusso', ''), 'Flusso ' || (x->>'workflow_id')), 120), 'flussi', 'esecuzione',
            left(coalesce(nullif(x->>'flusso', ''), 'Flusso'), 200), v_esito, x->>'id', x->>'workflow_id',
            case when v_ini is not null and v_fin is not null then greatest(0, (extract(epoch from (v_fin - v_ini)) * 1000)::int) end,
            base || '/workflow/' || (x->>'workflow_id') || '/executions/' || (x->>'id'),
            nullif(x->>'modo', ''))
    on conflict (esecuzione_id) where esecuzione_id is not null do update
      set esito = excluded.esito, durata_ms = excluded.durata_ms
      where suite_registro.esito = 'in_corso' and excluded.esito <> 'in_corso';
    if found then n_new := n_new + 1; end if;
  end loop;
  -- pulizia: esecuzioni andate bene dopo 60 giorni, tutto il resto dopo 400
  delete from suite_registro where azione = 'esecuzione' and esito = 'ok' and created_at < now() - interval '60 days';
  delete from suite_registro where created_at < now() - interval '400 days';
  return jsonb_build_object('ok', true, 'scritte', n_new);
end $$;
revoke all on function public.suite_registra(jsonb) from public, anon, authenticated;
revoke all on function public.suite_registra_esecuzioni(jsonb) from public, anon, authenticated;

------------------------------------------------------------------------
-- Tempo reale
------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'suite_registro') then
    alter publication supabase_realtime add table public.suite_registro;
  end if;
end $$;
