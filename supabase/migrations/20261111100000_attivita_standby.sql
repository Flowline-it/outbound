-- FlowLine Suite: stato «Stand-by» per le attività.
-- Da eseguire una volta nel SQL Editor del progetto Supabase "Lead Flowline". Si può rieseguire senza danni.
--
-- * attivita.stato accetta il nuovo valore 'standby' (attività ferme, da riprendere più avanti).
--   Nella Suite le attività in stand-by stanno in un gruppo a parte, chiuso, e non contano tra quelle da fare.
-- * Progetti: il valore 'pausa' esiste già; nella Suite ora si chiama «Stand-by». Nel database non cambia nulla.

do $$
declare c text;
begin
  -- tolgo il vecchio controllo sugli stati, qualunque nome abbia
  for c in
    select conname from pg_constraint
    where conrelid = 'public.attivita'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%stato%'
  loop
    execute format('alter table public.attivita drop constraint %I', c);
  end loop;
end $$;

alter table public.attivita
  add constraint attivita_stato_check
  check (stato in ('da_fare', 'in_corso', 'in_attesa', 'standby', 'fatto'));
