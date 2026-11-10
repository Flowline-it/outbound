-- =====================================================================
-- Foto profilo, Bacheca (categorie, scadenza, in alto) e email di riepilogo
--
-- 1. Foto profilo: team_members.avatar_url + bucket pubblico «avatars»
--    (ognuno scrive solo nella propria cartella <uuid>/).
-- 2. Bacheca: categoria e data di scadenza (la comunicazione sparisce dal
--    giorno dopo). Il riquadro Bacheca passa in cima alla Home di tutti.
-- 3. Email sulle attività assegnate: invece di una mail per attività, le
--    notifiche vanno «in_coda» e un flusso n8n orario manda un riepilogo
--    unico, secondo la scelta di ciascuno (team_members.avvisi_attivita).
--    Le comunicazioni di Bacheca continuano a partire subito.
-- Si può rilanciare più volte.
-- =====================================================================

-- 1. Foto profilo ----------------------------------------------------
alter table public.team_members add column if not exists avatar_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 1048576,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists avatars_insert on storage.objects;
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_update on storage.objects;
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_delete on storage.objects;
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- 2. Bacheca: categoria, scadenza, ordine -----------------------------
alter table public.bacheca add column if not exists categoria text not null default 'generale'
  check (length(categoria) between 1 and 30);
alter table public.bacheca add column if not exists scade_il date;
comment on column public.bacheca.scade_il is
  'Ultimo giorno in cui la comunicazione resta visibile; dal giorno dopo sparisce dalla Bacheca (la vede ancora l''autore, in «Scadute»). Vuota = non scade.';
create index if not exists bacheca_scade_idx on public.bacheca (scade_il);

-- il riquadro Bacheca passa in cima anche a chi aveva già salvato la propria Home
update public.team_members t
set home_layout = (
  select jsonb_agg(e.v order by (e.v->>'id') <> 'bacheca', e.ord)
  from jsonb_array_elements(t.home_layout) with ordinality as e(v, ord)
)
where jsonb_typeof(t.home_layout) = 'array'
  and exists (select 1 from jsonb_array_elements(t.home_layout) x where x->>'id' = 'bacheca')
  and (t.home_layout->0->>'id') is distinct from 'bacheca';

-- 3. Riepilogo email --------------------------------------------------
alter table public.notifiche drop constraint if exists notifiche_email_stato_check;
alter table public.notifiche add constraint notifiche_email_stato_check
  check (email_stato in ('non_richiesta','da_inviare','in_coda','inviata','errore'));

-- Come vuole ricevere le email sulle attività: subito (una per attività),
-- riepilogo ogni 2 / 4 ore, una volta al giorno, oppure mai.
alter table public.team_members add column if not exists avvisi_attivita text not null default 'ore_4'
  check (avvisi_attivita in ('subito','ore_2','ore_4','giornaliero','mai'));
alter table public.team_members add column if not exists riepilogo_inviato_il timestamptz;

-- l'invio di ogni tipo di notifica: 'subito' = una mail per notifica, 'riepilogo' = raggruppata
create or replace function public.notifiche_email_modo(p_tipo text, p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare pref text;
begin
  if p_tipo = 'bacheca' then return 'subito'; end if;
  if p_tipo = 'attivita_assegnata' then
    select avvisi_attivita into pref from public.team_members where id = p_user;
    return case coalesce(pref, 'ore_4') when 'mai' then null when 'subito' then 'subito' else 'riepilogo' end;
  end if;
  return null;
end $$;
revoke all on function public.notifiche_email_modo(text, uuid) from public, anon, authenticated;

create or replace function public.notifiche_email_prima()
returns trigger language plpgsql as $$
declare modo text;
begin
  if new.email_stato = 'non_richiesta' then
    modo := public.notifiche_email_modo(new.tipo, new.user_id);
    if modo = 'subito' then new.email_stato := 'da_inviare';
    elsif modo = 'riepilogo' then new.email_stato := 'in_coda';
    end if;
  end if;
  return new;
end $$;

-- Il flusso n8n orario chiama questa funzione: sceglie chi è «in scadenza» col
-- proprio riepilogo, segna le sue notifiche «inviata» (una volta sola) e
-- restituisce una riga per attività. Regole:
--  * solo tra le 8 e le 20 (ora italiana): di notte si accumula;
--  * dall'ultimo riepilogo deve essere passato l'intervallo scelto
--    (2 ore, 4 ore; «giornaliero» = una volta al giorno, dopo le 8);
--  * l'ultima attività in coda deve avere almeno 10 minuti, così una serie di
--    assegnazioni consecutive finisce nella stessa mail;
--  * si salta ciò che è già letto nella Suite, fatto o cancellato.
create or replace function public.riepilogo_attivita_prepara()
returns table (
  notifica_id bigint, destinatario_email text, destinatario_nome text,
  attivita_id bigint, attivita_titolo text, progetto text, scadenza date,
  urgente boolean, assegnata_il timestamptz, totale_in_ritardo int
) language plpgsql security definer set search_path = public as $$
declare ora_it timestamp := now() at time zone 'Europe/Rome';
begin
  if extract(hour from ora_it) < 8 or extract(hour from ora_it) >= 20 then return; end if;

  -- 1. persone pronte per il riepilogo
  drop table if exists _pronti;
  create temp table _pronti on commit drop as
  select t.id as user_id
  from public.team_members t
  where t.attivo and t.avvisi_attivita in ('ore_2','ore_4','giornaliero')
    and exists (select 1 from public.notifiche n
                where n.user_id = t.id and n.email_stato = 'in_coda')
    and not exists (select 1 from public.notifiche n
                    where n.user_id = t.id and n.email_stato = 'in_coda'
                      and n.created_at > now() - interval '10 minutes')
    and (case t.avvisi_attivita
           when 'giornaliero' then t.riepilogo_inviato_il is null
                or (t.riepilogo_inviato_il at time zone 'Europe/Rome')::date < ora_it::date
           else t.riepilogo_inviato_il is null
                or now() - t.riepilogo_inviato_il >=
                   (case t.avvisi_attivita when 'ore_2' then interval '2 hours' else interval '4 hours' end)
                   - interval '5 minutes'
         end);

  -- 2. quello che non serve più (già letto, attività fatta o cancellata) non si manda
  update public.notifiche n set email_stato = 'non_richiesta'
  where n.email_stato = 'in_coda' and n.user_id in (select user_id from _pronti)
    and (n.letta_il is not null
         or not exists (select 1 from public.attivita a where a.id = n.rif_id and a.stato <> 'fatto'));

  -- 3. prendo in carico il resto e restituisco i dati
  return query
  with c as (
    update public.notifiche n set email_stato = 'inviata'
    where n.email_stato = 'in_coda' and n.user_id in (select user_id from _pronti)
    returning n.id, n.user_id, n.rif_id, n.created_at
  ), m as (
    update public.team_members t set riepilogo_inviato_il = now()
    where t.id in (select distinct user_id from c) returning t.id
  )
  select c.id, t.email, t.nome, a.id, a.titolo, p.nome, a.scadenza, a.urgente, c.created_at,
         (select count(*)::int from public.attivita x
           where t.id = any(x.persone) and x.stato <> 'fatto' and x.scadenza < current_date)
  from c
  join public.team_members t on t.id = c.user_id
  join public.attivita a on a.id = c.rif_id
  left join public.progetti p on p.id = a.progetto_id
  order by t.nome, p.nome nulls last, a.urgente desc, a.scadenza nulls last, c.created_at;
end $$;
revoke all on function public.riepilogo_attivita_prepara() from public, anon, authenticated;

-- se il riepilogo non parte, il flusso segna «errore» le notifiche coinvolte
create or replace function public.riepilogo_attivita_errore(p_ids bigint[])
returns void language sql security definer set search_path = public as $$
  update public.notifiche set email_stato = 'errore' where id = any(p_ids) and email_stato = 'inviata'
$$;
revoke all on function public.riepilogo_attivita_errore(bigint[]) from public, anon, authenticated;

-- la mail immediata della Bacheca porta anche la categoria
drop function if exists public.notifica_email_prendi(bigint);
create function public.notifica_email_prendi(p_id bigint)
returns table (
  id bigint, tipo text, titolo text, testo text, rif_id bigint,
  destinatario_email text, destinatario_nome text,
  autore text, post_titolo text, post_testo text,
  attivita_titolo text, progetto text, scadenza date, urgente boolean, attivita_note text,
  post_categoria text
) language sql security definer set search_path = public as $$
  with c as (
    update public.notifiche n set email_stato = 'inviata'
    where n.id = p_id and n.email_stato = 'da_inviare'
    returning n.*
  )
  select c.id, c.tipo, c.titolo, c.testo, c.rif_id,
         t.email, t.nome,
         au.nome, b.titolo, b.testo,
         a.titolo, p.nome, a.scadenza, a.urgente, a.note,
         b.categoria
  from c
  join public.team_members t on t.id = c.user_id and t.attivo
  left join public.bacheca b on c.rif_tipo = 'bacheca' and b.id = c.rif_id
  left join public.team_members au on au.id = b.autore_id
  left join public.attivita a on c.rif_tipo = 'attivita' and a.id = c.rif_id
  left join public.progetti p on p.id = a.progetto_id
$$;
revoke all on function public.notifica_email_prendi(bigint) from public, anon, authenticated;
