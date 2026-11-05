-- Le call dell'agenda Azienda ricevono in automatico il link di Google Meet: lo crea il flusso n8n
-- «Calendario: Suite → Google» e lo scrive in eventi.link_call.
-- Qui si evita solo una notifica doppia: quando il link viene aggiunto dal sistema (non da una persona)
-- i partecipanti non ricevono «Evento modificato».
-- Si esegue una volta sola dal SQL Editor di Supabase (è ripetibile senza danni).

create or replace function public.notifiche_evento_cambiato()
returns trigger language plpgsql security definer set search_path = public as $$
declare tp text; ti text; tx text; nome text;
begin
  if new.fine < now() and new.inizio < now() then return new; end if;
  nome := public.evento_nome(new);
  if new.stato = 'annullato' and old.stato <> 'annullato' then
    tp := 'evento_annullato'; ti := 'Evento annullato';
    tx := 'È stato annullato: ' || nome || ', previsto ' || public.evento_quando(old.inizio, old.tutto_il_giorno) || '.';
  elsif new.stato = 'annullato' then
    return new;
  elsif new.inizio is distinct from old.inizio or new.fine is distinct from old.fine or new.tutto_il_giorno is distinct from old.tutto_il_giorno then
    tp := 'evento_spostato'; ti := 'Evento spostato';
    tx := 'È stato spostato: ' || nome || ', ora ' || public.evento_quando(new.inizio, new.tutto_il_giorno) || ' (era ' || public.evento_quando(old.inizio, old.tutto_il_giorno) || ').';
  elsif new.titolo is distinct from old.titolo or new.luogo is distinct from old.luogo
     or (new.link_call is distinct from old.link_call and not (auth.uid() is null and coalesce(btrim(old.link_call), '') = ''))
     or new.cliente is distinct from old.cliente or new.tipo is distinct from old.tipo then
    tp := 'evento_modificato'; ti := 'Evento modificato';
    tx := 'È stato modificato: ' || nome || ', ' || public.evento_quando(new.inizio, new.tutto_il_giorno) || '.';
  else
    return new;
  end if;
  insert into public.notifiche (user_id, tipo, titolo, testo, evento_id)
  select p.user_id, tp, ti, tx, new.id
  from public.evento_partecipanti p
  where p.evento_id = new.id and p.user_id is distinct from auth.uid();
  return new;
end $$;
revoke all on function public.notifiche_evento_cambiato() from public, anon, authenticated;
