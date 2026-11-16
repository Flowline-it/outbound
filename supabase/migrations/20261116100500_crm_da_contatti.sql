-- FlowLine Suite: dai contatti di Outbound e di LinkedIn al CRM (16 novembre 2026)
-- Pulsante «Porta nel CRM»: crm_porta_contatto('outbound' | 'linkedin', id)
--  * cerca l'azienda già nel CRM (stessa email o dominio, stesso sito, oppure stesso nome senza «S.r.l.» e simili);
--    se non c'è la crea con quello che sappiamo (email, sito, città, provenienza, primo contatto);
--  * se c'è, completa solo i campi vuoti e porta avanti lo stato (mai indietro);
--  * aggiunge la persona come referente (LinkedIn: il nome; Outbound: chi ha risposto, se non è una casella generica);
--  * segna il collegamento sul contatto (crm_azienda_id) e scrive nella cronologia dell'azienda (crm_registro).
-- Da lì in poi i flussi «Gmail → CRM», «Drive → CRM» e il Calendario riconoscono l'azienda e la aggiornano da soli.
-- Richiede 20261112100000_crm.sql e 20261112200000_crm_automatico.sql. Si può rieseguire.

alter table public.linkedin_contatti add column if not exists crm_azienda_id bigint references public.crm_aziende(id) on delete set null;
alter table public.contacts add column if not exists crm_azienda_id bigint references public.crm_aziende(id) on delete set null;

-- «Rossi S.r.l. - Carpenteria metallica» -> «rossi»
create or replace function public.crm_nome_norm(t text) returns text language sql immutable as $$
  select nullif(trim(regexp_replace(regexp_replace(regexp_replace(lower(split_part(coalesce(t, ''), ' - ', 1)),
    '\m(s\.?\s?r\.?\s?l\.?s?|s\.?\s?p\.?\s?a\.?|s\.?\s?n\.?\s?c\.?|s\.?\s?a\.?\s?s\.?|soc\.?\s?coop\.?|unipersonale|societ[aà] agricola|ditta|impresa)\M', ' ', 'g'),
    '[^a-z0-9àèéìòù ]', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;
-- nome da mostrare: «Rossi S.r.l. - Carpenteria metallica» -> «Rossi S.r.l.»
create or replace function public.crm_nome_pulito(t text) returns text language sql immutable as $$
  select nullif(trim(split_part(coalesce(t, ''), ' - ', 1)), '')
$$;
-- caselle che non sono una persona
create or replace function public.crm_casella_generica(e text) returns boolean language sql immutable as $$
  select e is null or split_part(lower(e), '@', 1) ~ '^(info|ordini|amministrazione|segreteria|commerciale|acquisti|ufficio|office|contatti|contact|sales|mail|posta|admin|direzione|vendite|tecnico|produzione|qualita|hr|noreply|no-reply|staff|shop|negozio|export|logistica)([._-].*)?$'
$$;

create or replace function public.crm_porta_contatto(p_fonte text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  l linkedin_contatti; c contacts;
  v_nome text; v_persona text; v_ruolo text; v_mail text; v_mail_persona text; v_sito text; v_citta text; v_prov text; v_stato text;
  v_primo_il date; v_primo text; v_note text; v_segue uuid; v_link text; v_canale text[]; v_gia bigint; v_ultimo date;
  az bigint; nuova boolean := false; ref bigint; mods jsonb := '[]'::jsonb; a crm_aziende; ord text[] := array['da_contattare','contattato','programmato','trattativa','preventivo','progetto','assistenza','concluso'];
  rep jsonb; v_from text;
begin
  if not team_is_member() then raise exception 'Solo la squadra può aggiungere contatti al CRM'; end if;

  if p_fonte = 'linkedin' then
    select * into l from linkedin_contatti where id = p_id::bigint;
    if not found then raise exception 'Contatto LinkedIn non trovato'; end if;
    v_gia := l.crm_azienda_id;
    v_nome := coalesce(nullif(trim(l.azienda), ''), nullif(trim(l.nome), ''));
    v_persona := case when nullif(trim(l.azienda), '') is not null then nullif(trim(l.nome), '') end;
    v_ruolo := nullif(trim(l.ruolo), '');
    v_mail := nullif(trim(l.email), '');
    v_mail_persona := v_mail;
    v_link := nullif(trim(l.url_profilo), '');
    v_canale := array['linkedin'];
    v_prov := 'LinkedIn';
    v_stato := case l.stato when 'esito_negativo' then 'negativo' when 'da_contattare' then 'da_contattare' else 'contattato' end;
    v_primo_il := coalesce(l.messaggio_il, l.invito_il, l.created_at::date);
    v_ultimo := coalesce(l.messaggio_il, l.invito_il);
    v_primo := concat_ws(E'\n\n',
      'Contatto LinkedIn' || coalesce(' (' || v_persona || ')', '') || '.',
      case when l.messaggio is not null then 'Messaggio inviato' || coalesce(' il ' || to_char(l.messaggio_il, 'DD/MM/YYYY'), '') || ': ' || left(l.messaggio, 1500) end,
      case when l.risposta is not null then 'Risposta: ' || left(l.risposta, 1500) end);
    v_note := concat_ws(E'\n', nullif(l.descrizione, ''), nullif(l.note, ''));
    v_segue := l.competenza_di;
  elsif p_fonte = 'outbound' then
    select * into c from contacts where id = p_id;
    if not found then raise exception 'Contatto Outbound non trovato'; end if;
    v_gia := c.crm_azienda_id;
    v_nome := coalesce(crm_nome_pulito(c.azienda), nullif(trim(c.email), ''));
    v_mail := nullif(trim(c.email), '');
    v_sito := nullif(trim(c.sito_web), '');
    v_citta := nullif(trim(split_part(coalesce(c.sede, ''), ',', 1)), '');
    v_prov := 'Sistema di outbound';
    v_stato := case when c.ha_risposto or coalesce(c.step, 0) > 0 or c.data_ultimo_invio is not null then 'contattato' else 'da_contattare' end;
    v_primo_il := coalesce(c.anchor_date, c.data_ultimo_invio);
    v_ultimo := coalesce((nullif(c.data->'reply'->>'date', ''))::timestamptz::date, c.data_ultimo_invio);
    v_canale := array['email'];
    rep := c.data->'reply';
    v_primo := concat_ws(E'\n\n',
      'Email a freddo da Outbound' || case when c.oggetto is not null then ' («' || left(c.oggetto, 140) || '»)' else '' end
        || ': ' || coalesce(jsonb_array_length(c.data->'history'), 0) || ' email inviate'
        || coalesce(', la prima il ' || to_char(c.anchor_date, 'DD/MM/YYYY'), '') || '.',
      case when c.ha_risposto and rep is not null then
        'Risposta' || coalesce(' del ' || to_char((rep->>'date')::timestamptz at time zone 'Europe/Rome', 'DD/MM/YYYY'), '')
        || coalesce(' da ' || nullif(rep->>'from', ''), '') || ': ' || left(coalesce(rep->>'snippet', ''), 1200) end);
    v_note := concat_ws(E'\n', case when nullif(c.settore, '') is not null then 'Settore (da Outbound): ' || c.settore end, nullif(c.descrizione, ''));
    -- chi ha risposto, se è una persona e non una casella generica: «Roberto - Elettrozincatura <rpintossi@…>»
    v_from := rep->>'from';
    if c.ha_risposto and v_from is not null then
      v_mail_persona := (crm_indirizzi(v_from))[1];
      if v_mail_persona is not null and not crm_casella_generica(v_mail_persona) and not crm_dominio_squadra(crm_dominio(v_mail_persona)) then
        v_persona := nullif(trim(both ' "' from split_part(split_part(v_from, '<', 1), ' - ', 1)), '');
        if v_persona is null or v_persona ~ '@' then v_persona := split_part(v_mail_persona, '@', 1); end if;
      else
        v_mail_persona := null;
      end if;
    end if;
    if v_persona is null and nullif(trim(c.ruolo), '') is not null and not crm_casella_generica(c.email) then
      v_persona := trim(c.ruolo); v_mail_persona := c.email;
    end if;
  else
    raise exception 'Fonte sconosciuta: %', p_fonte;
  end if;
  if v_nome is null then raise exception 'Al contatto manca il nome dell''azienda'; end if;

  -- già collegato e l'azienda esiste ancora
  if v_gia is not null and exists (select 1 from crm_aziende where id = v_gia) then
    return jsonb_build_object('ok', true, 'azienda_id', v_gia, 'gia', true);
  end if;

  -- 1. stessa email / dominio (persone e aziende già nel CRM)
  if v_mail is not null then
    select x.azienda_id into az from crm_aziende_da_email(array[v_mail] || coalesce(v_mail_persona, v_mail)) x
      order by case x.come when 'persona' then 0 when 'email azienda' then 1 else 2 end limit 1;
  end if;
  -- 2. stesso sito
  if az is null and crm_dominio_sito(v_sito) is not null then
    select id into az from crm_aziende where crm_dominio_sito(sito) = crm_dominio_sito(v_sito) order by id limit 1;
  end if;
  -- 3. stesso nome
  if az is null and crm_nome_norm(v_nome) is not null then
    select id into az from crm_aziende where crm_nome_norm(nome) = crm_nome_norm(v_nome) order by id limit 1;
  end if;

  if az is null then
    insert into crm_aziende (nome, stato, provenienza, email, sito, citta, primo_contatto_il, primo_contatto, note, segue, creato_da)
    values (left(v_nome, 300), v_stato, v_prov,
            case when v_mail is not null and not crm_dominio_generico(crm_dominio(v_mail)) or p_fonte = 'outbound' then v_mail end,
            v_sito, v_citta, v_primo_il, v_primo, nullif(v_note, ''), coalesce(v_segue, auth.uid()), auth.uid())
    returning id into az;
    nuova := true;
  else
    select * into a from crm_aziende where id = az;
    update crm_aziende set
      email = coalesce(nullif(email, ''), case when p_fonte = 'outbound' then v_mail end),
      sito = coalesce(nullif(sito, ''), v_sito),
      citta = coalesce(nullif(citta, ''), v_citta),
      provenienza = coalesce(nullif(provenienza, ''), v_prov),
      primo_contatto_il = coalesce(primo_contatto_il, v_primo_il),
      primo_contatto = coalesce(nullif(primo_contatto, ''), v_primo),
      segue = coalesce(segue, v_segue),
      stato = case when v_stato = 'contattato' and stato = 'da_contattare' then 'contattato' else stato end
    where id = az;
    if v_stato = 'contattato' and a.stato = 'da_contattare' then
      mods := mods || jsonb_build_object('t', 'crm_aziende', 'id', az, 'campo', 'stato', 'prima', a.stato, 'dopo', 'contattato');
    end if;
  end if;

  -- referente
  if v_persona is not null then
    select r.id into ref from crm_referenti r
      where az = any (r.aziende)
        and ((v_mail_persona is not null and lower(v_mail_persona) = any (crm_indirizzi(r.email)))
             or lower(trim(r.nome)) = lower(v_persona)
             or (v_link is not null and r.linkedin = v_link))
      limit 1;
    if ref is null then
      insert into crm_referenti (aziende, nome, ruolo, email, linkedin, canale, ultimo_contatto, creato_da)
      values (array[az], left(v_persona, 200), v_ruolo, v_mail_persona, v_link, v_canale, v_ultimo, auth.uid())
      returning id into ref;
      mods := mods || jsonb_build_object('t', 'crm_referenti', 'id', ref, 'op', 'insert');
    else
      update crm_referenti set
        ruolo = coalesce(nullif(ruolo, ''), v_ruolo), email = coalesce(nullif(email, ''), v_mail_persona),
        linkedin = coalesce(nullif(linkedin, ''), v_link), ultimo_contatto = greatest(ultimo_contatto, v_ultimo)
      where id = ref;
    end if;
  end if;

  -- collegamento sul contatto
  if p_fonte = 'linkedin' then update linkedin_contatti set crm_azienda_id = az where id = l.id;
  else update contacts set crm_azienda_id = az where id = c.id; end if;

  -- cronologia dell'azienda
  insert into crm_registro (azienda_id, fonte, fonte_id, tipo, titolo, testo, modifiche)
  values (az, 'suite', p_fonte || ':' || p_id, 'contatto',
          case when nuova then 'Aggiunta' else 'Collegata' end || ' da ' || case p_fonte when 'linkedin' then 'LinkedIn' else 'Outbound' end
            || coalesce(' (' || v_persona || ')', ''),
          left(v_primo, 3000), mods)
  on conflict do nothing;

  return jsonb_build_object('ok', true, 'azienda_id', az, 'nuova', nuova, 'referente_id', ref, 'nome', (select nome from crm_aziende where id = az));
end $$;
revoke all on function public.crm_porta_contatto(text, text) from public, anon;
grant execute on function public.crm_porta_contatto(text, text) to authenticated;
