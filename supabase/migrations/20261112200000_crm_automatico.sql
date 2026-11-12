-- FlowLine Suite: CRM che si aggiorna da solo (Gmail info@flowline.it, Calendario, Google Drive).
-- Richiede 20261112100000_crm.sql. Da eseguire nel SQL Editor del progetto "Lead Flowline". Si può rieseguire.
--
-- Come funziona:
--  * crm_registro: la cronologia «Cosa è successo» di ogni azienda. Ogni aggiornamento automatico scrive qui
--    da dove arriva (mail, evento, file), che cosa ha cambiato (modifiche) e si può annullare con crm_annulla(id).
--  * crm_visti: mail e file già esaminati, per non leggerli due volte.
--  * Calendario: quando un evento dell'agenda Azienda ha come ospite una persona (o un dominio) di un'azienda del
--    CRM, nasce l'incontro nella pagina dell'azienda («Secondo incontro», «Terzo incontro»…), senza flussi esterni.
--  * Gmail: il flusso n8n «Suite: Gmail → CRM» chiede a crm_gmail_candidati quali mail riguardano un cliente,
--    le fa leggere a Claude e passa la decisione a crm_applica.
--  * Drive: il flusso n8n «Suite: Drive → CRM» passa i file nuovi a crm_drive_nuovi, che li collega al progetto e
--    all'azienda (e segna «contratto firmato» quando il nome lo dice).

------------------------------------------------------------------------
-- Tabelle
------------------------------------------------------------------------
create table if not exists public.crm_registro (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  azienda_id    bigint references public.crm_aziende(id) on delete cascade,
  progetto_id   bigint references public.progetti(id) on delete set null,
  fonte         text not null check (fonte in ('gmail','calendario','drive','suite')),
  fonte_id      text not null,
  fonte_url     text,
  tipo          text not null default 'aggiornamento',
  titolo        text not null,
  testo         text,
  modifiche     jsonb not null default '[]'::jsonb,   -- [{t, id, op:'insert'} | {t, id, campo, prima, dopo}]
  annullato_il  timestamptz,
  annullato_da  uuid references public.team_members(id) on delete set null
);
create unique index if not exists crm_registro_fonte_key on public.crm_registro (fonte, fonte_id, coalesce(azienda_id, 0));
create index if not exists crm_registro_azienda_idx on public.crm_registro (azienda_id, created_at desc);
create index if not exists crm_registro_recenti_idx on public.crm_registro (created_at desc);

create table if not exists public.crm_visti (
  fonte      text not null,
  fonte_id   text not null,
  created_at timestamptz not null default now(),
  esito      text,
  primary key (fonte, fonte_id)
);

alter table public.crm_incontri add column if not exists evento_id bigint;
do $$ begin
  alter table public.crm_incontri add constraint crm_incontri_evento_fk foreign key (evento_id) references public.eventi(id) on delete set null;
exception when duplicate_object then null; end $$;
create index if not exists crm_incontri_evento_idx on public.crm_incontri (evento_id);
alter table public.crm_documenti add column if not exists fonte text;
alter table public.crm_documenti add column if not exists fonte_id text;
create unique index if not exists crm_documenti_fonte_key on public.crm_documenti (fonte, fonte_id) where fonte_id is not null;

alter table public.crm_registro enable row level security;
revoke all on public.crm_registro from anon;
drop policy if exists crm_registro_leggi on public.crm_registro;
create policy crm_registro_leggi on public.crm_registro for select to authenticated using (public.team_is_member());
alter table public.crm_visti enable row level security;
revoke all on public.crm_visti from anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.crm_registro;
exception when duplicate_object then null; when undefined_object then null; end $$;

------------------------------------------------------------------------
-- Utilità: indirizzi e domini
------------------------------------------------------------------------
-- tutti gli indirizzi email contenuti in un testo ("Email: a@x.it\nPEC: b@pec.it" -> {a@x.it, b@pec.it})
create or replace function public.crm_indirizzi(t text) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct m[1]), '{}') from regexp_matches(lower(coalesce(t, '')), '([a-z0-9._%+''-]+@[a-z0-9.-]+\.[a-z]{2,})', 'g') m
$$;
-- domini di posta generici: non identificano un'azienda
create or replace function public.crm_dominio_generico(d text) returns boolean language sql immutable as $$
  select d is null or d ~ '^(gmail\.com|googlemail\.com|libero\.it|hotmail\.|outlook\.|live\.|yahoo\.|icloud\.com|me\.com|msn\.com|alice\.it|tin\.it|virgilio\.it|tiscali\.it|fastwebnet\.it|email\.it|gmx\.|protonmail\.|proton\.me|aruba\.it|flowline\.it|flowline-ia\.it)'
      or d ~ '(^|\.)(legalmail\.it|pec\.it|postecert\.it|arubapec\.it|cert\.legalmail\.it|pec\.[a-z.]+)$' or d like 'pec.%'
$$;
-- domini della squadra (info@flowline.it e le caselle dell'outbound)
create or replace function public.crm_dominio_squadra(d text) returns boolean language sql immutable as $$
  select coalesce(d, '') in ('flowline.it', 'flowline-ia.it')
$$;
create or replace function public.crm_dominio(e text) returns text language sql immutable as $$
  select nullif(regexp_replace(lower(split_part(coalesce(e, ''), '@', 2)), '^(www\.|mail\.)', ''), '')
$$;
-- dominio del sito: "https://www.rossi.it/chi-siamo" -> rossi.it
create or replace function public.crm_dominio_sito(s text) returns text language sql immutable as $$
  select nullif(regexp_replace(lower(split_part(regexp_replace(coalesce(s, ''), '^[a-z]+://', '', 'i'), '/', 1)), '^www\.', ''), '')
$$;
create or replace function public.crm_ordinale(n int) returns text language sql immutable as $$
  select (array['Primo','Secondo','Terzo','Quarto','Quinto','Sesto','Settimo','Ottavo','Nono','Decimo'])[n]
$$;

-- aziende che corrispondono a un elenco di indirizzi: prima le persone note, poi l'email dell'azienda, poi il dominio
create or replace function public.crm_aziende_da_email(mails text[])
returns table (azienda_id bigint, referenti bigint[], come text)
language sql stable security definer set search_path = public as $$
  with m as (select distinct lower(x) as e from unnest(coalesce(mails, '{}')) x where x like '%@%'),
  d as (select distinct crm_dominio(e) as dom from m where not crm_dominio_generico(crm_dominio(e))),
  per_persona as (
    select az as azienda_id, array_agg(distinct r.id) as referenti
    from crm_referenti r cross join lateral unnest(r.aziende) az
    where exists (select 1 from m where m.e = any (crm_indirizzi(r.email)))
    group by az
  ),
  per_azienda as (
    select a.id as azienda_id from crm_aziende a where exists (select 1 from m where m.e = any (crm_indirizzi(a.email)))
  ),
  per_dominio as (
    select a.id as azienda_id from crm_aziende a, d
    where d.dom = crm_dominio_sito(a.sito)
       or exists (select 1 from unnest(crm_indirizzi(a.email)) x where crm_dominio(x) = d.dom)
       or exists (select 1 from crm_referenti r where a.id = any (r.aziende) and exists (select 1 from unnest(crm_indirizzi(r.email)) x where crm_dominio(x) = d.dom))
  )
  select p.azienda_id, p.referenti, 'persona' from per_persona p join crm_aziende a on a.id = p.azienda_id
  union all
  select x.azienda_id, '{}', 'email azienda' from per_azienda x where x.azienda_id not in (select azienda_id from per_persona)
  union all
  select x.azienda_id, '{}', 'dominio' from (select distinct azienda_id from per_dominio) x
  where x.azienda_id not in (select azienda_id from per_persona) and x.azienda_id not in (select azienda_id from per_azienda)
$$;

-- tutto quello che serve a Claude per capire una mail su un'azienda
create or replace function public.crm_contesto_azienda(p_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', a.id, 'nome', a.nome, 'stato', a.stato, 'settore', a.settore,
    'referenti', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'nome', r.nome, 'ruolo', r.ruolo, 'email', r.email)) from crm_referenti r where a.id = any (r.aziende)), '[]'),
    'preventivi', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'nome', v.nome, 'stato', v.stato, 'importo', v.importo, 'inviato_il', v.inviato_il) order by v.id desc) from crm_preventivi v where a.id = any (v.aziende) and v.stato <> 'rifiutato'), '[]'),
    'progetti', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'stato', p.stato, 'drive_id', p.drive_id, 'cartelle', p.drive_cartelle) order by p.id desc) from progetti p where p.azienda_id = a.id and p.stato <> 'chiuso'), '[]'),
    'incontri', (select count(*) from crm_incontri i where a.id = any (i.aziende)),
    'ultimi_incontri', coalesce((select jsonb_agg(x) from (select jsonb_build_object('titolo', i.titolo, 'data', i.data) as x from crm_incontri i where a.id = any (i.aziende) order by i.data desc nulls last limit 3) s), '[]'),
    'ultimi_aggiornamenti', coalesce((select jsonb_agg(x) from (select jsonb_build_object('quando', g.created_at, 'titolo', g.titolo) as x from crm_registro g where g.azienda_id = a.id and g.annullato_il is null order by g.created_at desc limit 5) s), '[]')
  ) from crm_aziende a where a.id = p_id
$$;

------------------------------------------------------------------------
-- Gmail: quali mail nuove riguardano un'azienda del CRM
-- input: {"messaggi":[{"id","thread_id","from","subject","snippet","emails":[...]}]} (anche le mail inviate da noi)
------------------------------------------------------------------------
create or replace function public.crm_gmail_candidati(p jsonb)
returns table (msg_id text, thread_id text, oggetto text, aziende jsonb)
language plpgsql security definer set search_path = public as $$
declare m jsonb; az jsonb;
begin
  for m in select * from jsonb_array_elements(coalesce(p->'messaggi', '[]')) loop
    continue when exists (select 1 from crm_visti v where v.fonte = 'gmail' and v.fonte_id = m->>'id');
    -- mail solo fra persone della squadra (o avvisi della Suite): niente da leggere
    if not exists (select 1 from unnest(crm_indirizzi(coalesce(m->>'from', '') || ' ' || coalesce(m->'emails', '[]')::text)) x where not crm_dominio_squadra(crm_dominio(x))) then
      insert into crm_visti (fonte, fonte_id, esito) values ('gmail', m->>'id', 'interna') on conflict do nothing;
      continue;
    end if;
    select coalesce(jsonb_agg(crm_contesto_azienda(c.azienda_id) || jsonb_build_object('abbinata_per', c.come, 'referenti_in_mail', c.referenti)), '[]')
      into az
    from (select * from crm_aziende_da_email(array(select jsonb_array_elements_text(coalesce(m->'emails', '[]')))) limit 3) c;
    if jsonb_array_length(az) = 0 then
      insert into crm_visti (fonte, fonte_id, esito) values ('gmail', m->>'id', 'nessun_cliente') on conflict do nothing;
      continue;
    end if;
    msg_id := m->>'id'; thread_id := m->>'thread_id'; oggetto := m->>'subject'; aziende := az;
    return next;
  end loop;
end $$;

------------------------------------------------------------------------
-- Applica un aggiornamento deciso da Claude (o da un flusso) e lo scrive nel registro.
-- input (tutti facoltativi tranne fonte e fonte_id):
-- {"fonte":"gmail","fonte_id":"<id mail>","fonte_url":"…","rilevante":true,"azienda_id":12,"progetto_id":5,
--  "tipo":"contratto_firmato","titolo":"…","testo":"…","nuovo_stato":"progetto",
--  "preventivo":{"id":3,"stato":"accettato"},"incontro":{"titolo":"…","data":"2026-11-20T10:00:00+01:00"},
--  "verbale":"…" (va nell'ultimo incontro passato senza verbale),
--  "documenti":[{"nome":"…","url":"…","drive_id":"…"}],"attivita":[{"titolo":"…","persone":["giuseppe"]}],
--  "referente_nuovo":{"nome":"…","email":"…","ruolo":"…"}}
------------------------------------------------------------------------
create or replace function public.crm_applica(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f text := coalesce(p->>'fonte', 'gmail'); fid text := p->>'fonte_id';
  az bigint := nullif(p->>'azienda_id', '')::bigint; pr bigint := nullif(p->>'progetto_id', '')::bigint;
  mods jsonb := '[]'::jsonb; reg_id bigint; st_prima text; st_nuovo text := nullif(p->>'nuovo_stato', '');
  rk_prima int; rk_nuovo int; x jsonb; nid bigint; d timestamptz; tit text; n int; v_prima text;
  rank constant jsonb := '{"da_contattare":1,"contattato":2,"programmato":3,"trattativa":4,"preventivo":5,"progetto":6,"assistenza":7,"concluso":8}';
begin
  if fid is null then return jsonb_build_object('ok', false, 'errore', 'manca fonte_id'); end if;
  -- il flusso non è riuscito a leggere la mail: non la segno come vista, così al prossimo giro si riprova
  if coalesce((p->>'riprova')::boolean, false) then return jsonb_build_object('ok', false, 'riprova', true); end if;
  if exists (select 1 from crm_registro where fonte = f and fonte_id = fid) then
    insert into crm_visti (fonte, fonte_id, esito) values (f, fid, 'gia_registrata') on conflict do nothing;
    return jsonb_build_object('ok', true, 'gia', true);
  end if;
  if az is not null and not exists (select 1 from crm_aziende where id = az) then az := null; end if;
  if pr is not null and not exists (select 1 from progetti where id = pr) then pr := null; end if;
  if coalesce((p->>'rilevante')::boolean, true) = false or az is null then
    insert into crm_visti (fonte, fonte_id, esito) values (f, fid, 'non_rilevante') on conflict do nothing;
    return jsonb_build_object('ok', true, 'rilevante', false);
  end if;
  if pr is null then select id into pr from progetti where azienda_id = az and stato <> 'chiuso' order by (stato in ('attivo','assistenza')) desc, id desc limit 1; end if;

  -- stato dell'azienda: si va solo avanti (o a «negativo»); mai indietro da solo
  select stato into st_prima from crm_aziende where id = az;
  if st_nuovo is not null and st_nuovo <> st_prima and st_nuovo in ('da_contattare','contattato','programmato','trattativa','preventivo','progetto','assistenza','concluso','rete','negativo') then
    rk_prima := coalesce((rank->>st_prima)::int, 0); rk_nuovo := coalesce((rank->>st_nuovo)::int, 0);
    if st_nuovo = 'negativo' or st_prima in ('rete','negativo') or rk_nuovo > rk_prima then
      update crm_aziende set stato = st_nuovo where id = az;
      mods := mods || jsonb_build_object('t', 'crm_aziende', 'id', az, 'campo', 'stato', 'prima', st_prima, 'dopo', st_nuovo);
    end if;
  end if;

  -- preventivo
  if jsonb_typeof(p->'preventivo') = 'object' and nullif(p->'preventivo'->>'id', '') is not null
     and p->'preventivo'->>'stato' in ('da_preparare','in_lavorazione','inviato','accettato','rifiutato') then
    select stato into v_prima from crm_preventivi where id = (p->'preventivo'->>'id')::bigint and az = any (aziende);
    if found and v_prima <> p->'preventivo'->>'stato' then
      update crm_preventivi set stato = p->'preventivo'->>'stato',
        inviato_il = case when p->'preventivo'->>'stato' = 'inviato' then coalesce(inviato_il, current_date) else inviato_il end
      where id = (p->'preventivo'->>'id')::bigint;
      mods := mods || jsonb_build_object('t', 'crm_preventivi', 'id', (p->'preventivo'->>'id')::bigint, 'campo', 'stato', 'prima', v_prima, 'dopo', p->'preventivo'->>'stato');
    end if;
  end if;

  -- incontro fissato o avvenuto (se nel Calendario c'è già un incontro vicino a quella data, non lo doppio)
  if jsonb_typeof(p->'incontro') = 'object' then
    d := nullif(p->'incontro'->>'data', '')::timestamptz;
    if d is null or not exists (select 1 from crm_incontri i where az = any (i.aziende) and i.data between d - interval '1 day' and d + interval '1 day') then
      select count(*) into n from crm_incontri i where az = any (i.aziende) and (d is null or i.data is null or i.data < d);
      tit := coalesce(nullif(p->'incontro'->>'titolo', ''), coalesce(crm_ordinale(n + 1), 'Nuovo') || ' incontro');
      insert into crm_incontri (aziende, titolo, data, verbale, prossimi_passi)
      values (array[az], tit, d, nullif(p->'incontro'->>'verbale', ''), nullif(p->'incontro'->>'prossimi_passi', ''))
      returning id into nid;
      mods := mods || jsonb_build_object('t', 'crm_incontri', 'id', nid, 'op', 'insert');
    end if;
  end if;

  -- verbale (es. appunti mandati dopo una call): va nell'ultimo incontro passato che non ne ha uno
  if nullif(p->>'verbale', '') is not null then
    select id into nid from crm_incontri i where az = any (i.aziende) and coalesce(i.verbale, '') = '' and (i.data is null or i.data <= now() + interval '2 hours')
      order by i.data desc nulls last limit 1;
    if found then
      update crm_incontri set verbale = p->>'verbale' where id = nid;
      mods := mods || jsonb_build_object('t', 'crm_incontri', 'id', nid, 'campo', 'verbale', 'prima', null, 'dopo', p->>'verbale');
    end if;
  end if;

  -- documenti (già caricati su Drive dal flusso)
  for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'documenti') = 'array' then p->'documenti' else '[]' end) loop
    continue when nullif(x->>'nome', '') is null;
    insert into crm_documenti (aziende, progetto_id, nome, url, data, fonte, fonte_id)
    values (array[az], pr, x->>'nome', nullif(x->>'url', ''), current_date, case when nullif(x->>'drive_id', '') is not null then 'drive' else f end, coalesce(nullif(x->>'drive_id', ''), fid || ':' || (x->>'nome')))
    on conflict (fonte, fonte_id) where fonte_id is not null do nothing
    returning id into nid;
    if nid is not null then mods := mods || jsonb_build_object('t', 'crm_documenti', 'id', nid, 'op', 'insert'); end if;
    if nullif(x->>'drive_id', '') is not null then
      insert into crm_visti (fonte, fonte_id, esito) values ('drive', x->>'drive_id', 'caricato_da_gmail') on conflict do nothing;
    end if;
    nid := null;
  end loop;

  -- attività da fare (solo se c'è un progetto)
  if pr is not null then
    for x in select * from jsonb_array_elements(case when jsonb_typeof(p->'attivita') = 'array' then p->'attivita' else '[]' end) loop
      continue when nullif(trim(x->>'titolo'), '') is null;
      insert into attivita (progetto_id, titolo, stato, persone, note)
      values (pr, left(trim(x->>'titolo'), 500), 'da_fare',
        coalesce((select array_agg(t.id) from team_members t where exists (select 1 from jsonb_array_elements_text(coalesce(x->'persone', '[]')) y where lower(t.nome) like lower(y) || '%')), '{}'),
        'Aggiunta in automatico da ' || case f when 'gmail' then 'una mail' when 'drive' then 'un file di Drive' else f end || coalesce(': ' || nullif(p->>'titolo', ''), '') || '.')
      returning id into nid;
      mods := mods || jsonb_build_object('t', 'attivita', 'id', nid, 'op', 'insert');
    end loop;
  end if;

  -- persona nuova dell'azienda (scrive da un indirizzo che non avevamo)
  if jsonb_typeof(p->'referente_nuovo') = 'object' and nullif(trim(p->'referente_nuovo'->>'nome'), '') is not null
     and not exists (select 1 from crm_referenti r where az = any (r.aziende) and (lower(r.nome) = lower(trim(p->'referente_nuovo'->>'nome'))
         or lower(coalesce(p->'referente_nuovo'->>'email', '-')) = any (crm_indirizzi(r.email)))) then
    insert into crm_referenti (aziende, nome, email, ruolo, note)
    values (array[az], trim(p->'referente_nuovo'->>'nome'), nullif(p->'referente_nuovo'->>'email', ''), nullif(p->'referente_nuovo'->>'ruolo', ''), 'Aggiunta in automatico da una mail.')
    returning id into nid;
    mods := mods || jsonb_build_object('t', 'crm_referenti', 'id', nid, 'op', 'insert');
  end if;

  insert into crm_registro (azienda_id, progetto_id, fonte, fonte_id, fonte_url, tipo, titolo, testo, modifiche)
  values (az, pr, f, fid, nullif(p->>'fonte_url', ''), coalesce(nullif(p->>'tipo', ''), 'aggiornamento'),
          left(coalesce(nullif(p->>'titolo', ''), 'Aggiornamento'), 300), nullif(p->>'testo', ''), mods)
  returning id into reg_id;
  insert into crm_visti (fonte, fonte_id, esito) values (f, fid, 'registrata') on conflict (fonte, fonte_id) do update set esito = 'registrata';
  return jsonb_build_object('ok', true, 'registro', reg_id, 'modifiche', jsonb_array_length(mods));
end $$;

------------------------------------------------------------------------
-- Annulla un aggiornamento automatico (dalla Suite). Rimette i valori di prima solo se nel frattempo
-- nessuno li ha cambiati a mano; toglie righe e collegamenti creati (i file su Drive restano).
------------------------------------------------------------------------
create or replace function public.crm_annulla(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g crm_registro; m jsonb; n int := 0; k int;
begin
  if not public.team_is_member() then raise exception 'Solo la squadra può annullare'; end if;
  select * into g from crm_registro where id = p_id for update;
  if not found then raise exception 'Aggiornamento non trovato'; end if;
  if g.annullato_il is not null then return jsonb_build_object('ok', true, 'gia', true); end if;
  for m in select x from jsonb_array_elements(g.modifiche) with ordinality t(x, i) order by i desc loop
    if m->>'op' = 'insert' then
      if m->>'t' = 'crm_incontri' then delete from crm_incontri where id = (m->>'id')::bigint;
      elsif m->>'t' = 'crm_documenti' then delete from crm_documenti where id = (m->>'id')::bigint;
      elsif m->>'t' = 'crm_referenti' then delete from crm_referenti where id = (m->>'id')::bigint;
      elsif m->>'t' = 'attivita' then delete from attivita where id = (m->>'id')::bigint and stato <> 'fatto';
      end if;
    elsif m->>'campo' = 'stato' and m->>'t' = 'crm_aziende' then
      update crm_aziende set stato = m->>'prima' where id = (m->>'id')::bigint and stato = m->>'dopo';
    elsif m->>'campo' = 'stato' and m->>'t' = 'crm_preventivi' then
      update crm_preventivi set stato = m->>'prima' where id = (m->>'id')::bigint and stato = m->>'dopo';
    elsif m->>'campo' = 'verbale' and m->>'t' = 'crm_incontri' then
      update crm_incontri set verbale = m->>'prima' where id = (m->>'id')::bigint and verbale = m->>'dopo';
    end if;
    get diagnostics k = row_count; n := n + k;
  end loop;
  update crm_registro set annullato_il = now(), annullato_da = (select id from team_members where id = auth.uid()) where id = p_id;
  return jsonb_build_object('ok', true, 'righe', n);
end $$;
revoke all on function public.crm_annulla(bigint) from public, anon;
grant execute on function public.crm_annulla(bigint) to authenticated;

------------------------------------------------------------------------
-- Drive: file nuovi. input {"files":[{"id","name","mimeType","parents":[…],"antenati":[…],"webViewLink"}]}
-- (antenati = le cartelle sopra, dalla più vicina alla radice: il flusso le ricava dall'elenco delle cartelle)
-- Collega ogni file al progetto della prima cartella che riconosce (cartella del cliente o una sua sottocartella)
-- e all'azienda del progetto. I file fuori dalle cartelle dei progetti vengono solo segnati come visti.
------------------------------------------------------------------------
create or replace function public.crm_drive_nuovi(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; pr progetti; az bigint; firmato boolean; res jsonb; collegati int := 0; par text;
begin
  for x in select * from jsonb_array_elements(coalesce(p->'files', '[]')) loop
    continue when nullif(x->>'id', '') is null;
    continue when exists (select 1 from crm_visti v where v.fonte = 'drive' and v.fonte_id = x->>'id');
    continue when exists (select 1 from crm_documenti dd where dd.fonte = 'drive' and dd.fonte_id = x->>'id');
    pr := null;
    for par in select v from jsonb_array_elements_text(coalesce(x->'parents', '[]') || coalesce(x->'antenati', '[]')) with ordinality t(v, i) order by i loop
      continue when nullif(par, '') is null;
      select * into pr from progetti q where q.drive_id = par or exists (select 1 from jsonb_array_elements(q.drive_cartelle) c where c->>'id' = par)
        order by (q.stato <> 'chiuso') desc, q.id desc limit 1;
      exit when pr.id is not null;
    end loop;
    if pr.id is null then
      insert into crm_visti (fonte, fonte_id, esito) values ('drive', x->>'id', 'fuori_progetti') on conflict do nothing;
      continue;
    end if;
    az := pr.azienda_id;
    firmato := (x->>'name') ~* '(contratt|contract|accordo|incarico)' and (x->>'name') ~* '(firmat|signed|sottoscritt|controfirm)';
    res := crm_applica(jsonb_build_object(
      'fonte', 'drive', 'fonte_id', x->>'id', 'fonte_url', x->>'webViewLink', 'azienda_id', az, 'progetto_id', pr.id,
      'tipo', case when firmato then 'contratto_firmato' else 'documento' end,
      'titolo', case when firmato then 'Contratto firmato caricato su Drive' else 'Nuovo file su Drive: ' || (x->>'name') end,
      'testo', 'Cartella del progetto «' || pr.nome || '».',
      'nuovo_stato', case when firmato then 'progetto' end,
      'documenti', jsonb_build_array(jsonb_build_object('nome', x->>'name', 'url', x->>'webViewLink'))));
    -- progetto senza azienda: il file entra comunque tra i documenti del progetto
    if az is null then
      insert into crm_documenti (aziende, progetto_id, nome, url, data, fonte, fonte_id)
      values ('{}', pr.id, x->>'name', x->>'webViewLink', current_date, 'drive', x->>'id') on conflict do nothing;
      insert into crm_visti (fonte, fonte_id, esito) values ('drive', x->>'id', 'solo_progetto') on conflict do nothing;
    else
      -- crm_applica ha registrato il documento con fonte 'drive' e id del file
      update crm_documenti set fonte = 'drive', fonte_id = x->>'id' where fonte = 'drive' and fonte_id = (x->>'id') || ':' || (x->>'name');
      insert into crm_visti (fonte, fonte_id, esito) values ('drive', x->>'id', 'collegato') on conflict (fonte, fonte_id) do update set esito = 'collegato';
    end if;
    collegati := collegati + 1;
  end loop;
  return jsonb_build_object('collegati', collegati);
end $$;

------------------------------------------------------------------------
-- Calendario → incontri. Un evento dell'agenda Azienda con un ospite che appartiene a un'azienda del CRM
-- diventa un incontro nella pagina dell'azienda; se l'evento viene annullato, l'incontro (ancora senza
-- verbale) sparisce. Le persone della squadra si aggiungono quando arrivano i partecipanti.
------------------------------------------------------------------------
create or replace function public.crm_da_evento() returns trigger
language plpgsql security definer set search_path = public as $$
declare a record; n int; tit text; nid bigint; mods jsonb; st_prima text; r record;
begin
  if new.calendario <> 'azienda' then return new; end if;
  if new.stato = 'annullato' then
    for r in select i.id, i.aziende, i.titolo from crm_incontri i where i.evento_id = new.id and coalesce(i.verbale, '') = '' loop
      delete from crm_incontri where id = r.id;
      insert into crm_registro (azienda_id, fonte, fonte_id, fonte_url, tipo, titolo, testo)
      values (r.aziende[1], 'calendario', 'evento-' || new.id || '-annullato', new.google_link, 'incontro_annullato', r.titolo || ' annullato', new.titolo)
      on conflict do nothing;
    end loop;
    return new;
  end if;
  if coalesce(array_length(new.ospiti, 1), 0) = 0 then return new; end if;
  for a in select * from crm_aziende_da_email(new.ospiti) loop
    select i.id into nid from crm_incontri i where i.evento_id = new.id and a.azienda_id = any (i.aziende) limit 1;
    if found then
      update crm_incontri set data = new.inizio where id = nid and data is distinct from new.inizio;
      continue;
    end if;
    -- un incontro già scritto a mano per lo stesso giorno: lo collego all'evento invece di farne un altro
    select i.id into nid from crm_incontri i where a.azienda_id = any (i.aziende) and i.evento_id is null
      and i.data between new.inizio - interval '12 hours' and new.inizio + interval '12 hours' limit 1;
    if found then update crm_incontri set evento_id = new.id where id = nid; continue; end if;
    select count(*) into n from crm_incontri i where a.azienda_id = any (i.aziende) and (i.data is null or i.data < new.inizio);
    tit := coalesce(crm_ordinale(n + 1), 'Nuovo') || ' incontro';
    insert into crm_incontri (aziende, titolo, data, persone, referenti, evento_id)
    values (array[a.azienda_id], tit, new.inizio,
            coalesce((select array_agg(ep.user_id) from evento_partecipanti ep where ep.evento_id = new.id), '{}'), coalesce(a.referenti, '{}'), new.id)
    returning id into nid;
    mods := jsonb_build_array(jsonb_build_object('t', 'crm_incontri', 'id', nid, 'op', 'insert'));
    select stato into st_prima from crm_aziende where id = a.azienda_id;
    if st_prima in ('da_contattare', 'contattato') and new.inizio > now() then
      update crm_aziende set stato = 'programmato' where id = a.azienda_id;
      mods := mods || jsonb_build_object('t', 'crm_aziende', 'id', a.azienda_id, 'campo', 'stato', 'prima', st_prima, 'dopo', 'programmato');
    end if;
    insert into crm_registro (azienda_id, fonte, fonte_id, fonte_url, tipo, titolo, testo, modifiche)
    values (a.azienda_id, 'calendario', 'evento-' || new.id, new.google_link, 'incontro', tit || ' in calendario',
            new.titolo || ' · ' || to_char(new.inizio at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI'), mods)
    on conflict do nothing;
  end loop;
  return new;
end $$;
revoke all on function public.crm_da_evento() from public, anon, authenticated;
drop trigger if exists eventi_crm on public.eventi;
create trigger eventi_crm after insert or update of ospiti, stato, inizio on public.eventi
  for each row execute function public.crm_da_evento();

create or replace function public.crm_da_partecipante() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update crm_incontri set persone = array_append(persone, new.user_id)
  where evento_id = new.evento_id and not (new.user_id = any (persone));
  return new;
end $$;
revoke all on function public.crm_da_partecipante() from public, anon, authenticated;
drop trigger if exists evento_partecipanti_crm on public.evento_partecipanti;
create trigger evento_partecipanti_crm after insert on public.evento_partecipanti
  for each row execute function public.crm_da_partecipante();

-- le funzioni per i flussi n8n girano con la credenziale Postgres del database, non dalla Suite
revoke all on function public.crm_gmail_candidati(jsonb) from public, anon, authenticated;
revoke all on function public.crm_applica(jsonb) from public, anon, authenticated;
revoke all on function public.crm_drive_nuovi(jsonb) from public, anon, authenticated;
revoke all on function public.crm_contesto_azienda(bigint) from public, anon, authenticated;
revoke all on function public.crm_aziende_da_email(text[]) from public, anon, authenticated;
