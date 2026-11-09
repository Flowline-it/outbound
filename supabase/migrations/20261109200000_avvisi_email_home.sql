-- =====================================================================
-- Avvisi via email + Home personalizzabile
--
-- 1. Home: ogni persona salva ordine, visibilità e dimensione dei riquadri
--    in team_members.home_layout (la Suite funziona anche senza: in quel caso
--    la disposizione resta nel browser).
-- 2. Email di avviso: quando nasce una notifica di tipo «bacheca» (nuova
--    comunicazione, a tutta la squadra tranne chi la scrive) o
--    «attivita_assegnata» (qualcuno ti aggiunge a un'attività), la notifica
--    viene segnata «da_inviare» e il database chiama il flusso n8n
--    «Suite: email di avviso», che manda la mail e la segna «inviata».
--
-- Parametri nel Vault (una volta sola, dal SQL Editor; la chiave è la stessa
-- controllata dal flusso n8n nell'header x-flowline-key):
--   select vault.create_secret('https://leo98.app.n8n.cloud/webhook/flowline-avvisi', 'avvisi_webhook_url');
--   select vault.create_secret('<chiave lunga casuale>', 'avvisi_webhook_key');
-- Se mancano, non succede niente: le notifiche restano «da_inviare» e la
-- campanella nella Suite funziona come prima.
-- =====================================================================

create extension if not exists pg_net;

-- 1. Home personalizzabile ------------------------------------------------
alter table public.team_members add column if not exists home_layout jsonb;
comment on column public.team_members.home_layout is
  'Disposizione della Home scelta dalla persona: [{"id":"calls","show":true,"size":6}, …]. Vuota = disposizione predefinita.';

-- 2. Email di avviso ------------------------------------------------------
-- tipi di notifica che partono anche via email
create or replace function public.notifiche_email_tipo(p_tipo text)
returns boolean language sql immutable as $$
  select p_tipo in ('bacheca', 'attivita_assegnata')
$$;

-- prima di salvare: segno «da_inviare» le notifiche che vanno anche per email
create or replace function public.notifiche_email_prima()
returns trigger language plpgsql as $$
begin
  if public.notifiche_email_tipo(new.tipo) and new.email_stato = 'non_richiesta' then
    new.email_stato := 'da_inviare';
  end if;
  return new;
end $$;
drop trigger if exists notifiche_email_bi on public.notifiche;
create trigger notifiche_email_bi before insert on public.notifiche
  for each row execute function public.notifiche_email_prima();

-- dopo il salvataggio: chiamo n8n con l'id della notifica
create or replace function public.notifiche_email_invia()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare hook text; k text;
begin
  if new.email_stato <> 'da_inviare' then return new; end if;
  select decrypted_secret into hook from vault.decrypted_secrets where name = 'avvisi_webhook_url';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'avvisi_webhook_key';
  if hook is null or k is null then return new; end if;
  perform net.http_post(url := hook,
    body := jsonb_build_object('notifica_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-flowline-key', k),
    timeout_milliseconds := 10000);
  return new;
end $$;
revoke all on function public.notifiche_email_invia() from public, anon, authenticated;
drop trigger if exists notifiche_email_ai on public.notifiche;
create trigger notifiche_email_ai after insert on public.notifiche
  for each row execute function public.notifiche_email_invia();

-- Il flusso n8n prende in carico una notifica in modo atomico (niente doppioni
-- se la chiamata arriva due volte) e riceve tutto ciò che serve per la mail.
-- Si usa dal flusso con la credenziale Postgres «Lead Flowline».
create or replace function public.notifica_email_prendi(p_id bigint)
returns table (
  id bigint, tipo text, titolo text, testo text, rif_id bigint,
  destinatario_email text, destinatario_nome text,
  autore text, post_titolo text, post_testo text,
  attivita_titolo text, progetto text, scadenza date, urgente boolean, attivita_note text
) language sql security definer set search_path = public as $$
  with c as (
    update public.notifiche n set email_stato = 'inviata'
    where n.id = p_id and n.email_stato = 'da_inviare'
    returning n.*
  )
  select c.id, c.tipo, c.titolo, c.testo, c.rif_id,
         t.email, t.nome,
         au.nome, b.titolo, b.testo,
         a.titolo, p.nome, a.scadenza, a.urgente, a.note
  from c
  join public.team_members t on t.id = c.user_id and t.attivo
  left join public.bacheca b on c.rif_tipo = 'bacheca' and b.id = c.rif_id
  left join public.team_members au on au.id = b.autore_id
  left join public.attivita a on c.rif_tipo = 'attivita' and a.id = c.rif_id
  left join public.progetti p on p.id = a.progetto_id
$$;
revoke all on function public.notifica_email_prendi(bigint) from public, anon, authenticated;

-- se la mail non parte, il flusso la segna «errore» (si vede nella tabella notifiche)
create or replace function public.notifica_email_errore(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.notifiche set email_stato = 'errore' where id = p_id
$$;
revoke all on function public.notifica_email_errore(bigint) from public, anon, authenticated;
