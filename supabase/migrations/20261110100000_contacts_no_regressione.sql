-- =====================================================================
-- Outbound: il database non torna mai indietro sugli invii
--
-- Incidente del 9 novembre 2026: alle 12:08 sono partiti 66 follow-up; alle
-- 21:34 una scheda della Suite rimasta aperta da giorni ha riscritto 61 di
-- quei contatti con i suoi dati vecchi (step e ultimo invio di prima), e il
-- giorno dopo risultavano «in ritardo».
--
-- Regola: un aggiornamento che porta indietro lo step o la data dell'ultimo
-- invio viene ignorato e la riga resta com'era. Unica eccezione voluta:
-- «Ricomincia sequenza», che azzera tutto (step 0, nessun invio, nessuna
-- conversazione).
-- La correzione principale è nella Suite (non riscrive più righe non toccate
-- e ricarica i dati quando la scheda torna attiva); questa è la rete di
-- sicurezza lato database.
-- =====================================================================

create or replace function public.contacts_no_regressione()
returns trigger language plpgsql as $$
declare
  ricomincia boolean := coalesce(new.step, 0) = 0
                        and new.data_ultimo_invio is null
                        and new.anchor_date is null
                        and new.thread_id is null;
begin
  if ricomincia then
    return new;
  end if;
  if coalesce(new.step, 0) < coalesce(old.step, 0)
     or (old.data_ultimo_invio is not null
         and (new.data_ultimo_invio is null or new.data_ultimo_invio < old.data_ultimo_invio)) then
    raise log 'contacts %: aggiornamento ignorato, dati più vecchi (step % -> %, ultimo invio % -> %)',
      old.id, old.step, new.step, old.data_ultimo_invio, new.data_ultimo_invio;
    return old;   -- tengo la riga del database
  end if;
  return new;
end $$;

drop trigger if exists contacts_no_regressione on public.contacts;
create trigger contacts_no_regressione before update on public.contacts
  for each row execute function public.contacts_no_regressione();
