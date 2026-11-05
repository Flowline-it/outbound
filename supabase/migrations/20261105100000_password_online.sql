-- FlowLine Suite: archivio Password e presenza "Online".
--
--  * credenziali: servizio, utente, password (CIFRATA), note. La password non è mai leggibile dalla tabella:
--    si apre solo con password_rivela(), che la decifra per chi è nella squadra e lascia una riga nel registro.
--  * password_log: chi ha visto, creato, modificato o eliminato quale credenziale, e quando.
--  * La chiave di cifratura è un segreto casuale nel Vault di Supabase (password_archivio_key), creato qui sotto.
--    NON cancellarlo né sostituirlo: senza quella chiave le password già salvate non si possono più aprire.
--  * Online: regole per il canale Realtime privato "suite-online" (solo la squadra legge e scrive la presenza).
--
-- Si esegue una volta sola dal SQL Editor di Supabase (è ripetibile senza danni).

create extension if not exists pgcrypto with schema extensions;

-- chiave di cifratura (creata una sola volta, mai mostrata)
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'password_archivio_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'password_archivio_key', 'Chiave di cifratura dell''archivio password della Suite');
  end if;
end $$;

create or replace function public.password_key() returns text
language sql security definer stable set search_path = public, vault as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'password_archivio_key' limit 1
$$;
revoke all on function public.password_key() from public, anon, authenticated;

create table if not exists public.credenziali (
  id bigint generated always as identity primary key,
  servizio text not null check (length(btrim(servizio)) > 0),
  categoria text not null default 'Altro',
  url text,
  username text,
  pw_cifrata bytea,
  ha_password boolean generated always as (pw_cifrata is not null) stored,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.password_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid references auth.users(id) on delete set null,
  credenziale_id bigint,
  servizio text,
  azione text not null check (azione in ('crea', 'modifica', 'visto', 'elimina'))
);
create index if not exists password_log_created_idx on public.password_log (created_at desc);

alter table public.credenziali enable row level security;
alter table public.password_log enable row level security;

drop policy if exists credenziali_select on public.credenziali;
create policy credenziali_select on public.credenziali for select to authenticated using (public.team_is_member());
drop policy if exists credenziali_delete on public.credenziali;
create policy credenziali_delete on public.credenziali for delete to authenticated using (public.team_is_member());
drop policy if exists password_log_select on public.password_log;
create policy password_log_select on public.password_log for select to authenticated using (public.team_is_member());
-- niente policy di insert/update: si scrive solo con le funzioni qui sotto

-- la colonna cifrata non esce mai dalle query dirette
revoke all on public.credenziali from anon, authenticated;
revoke all on public.password_log from anon, authenticated;
grant select (id, servizio, categoria, url, username, ha_password, note, created_by, updated_by, created_at, updated_at) on public.credenziali to authenticated;
grant delete on public.credenziali to authenticated;
grant select on public.password_log to authenticated;

-- crea (p_id nullo) o modifica. p_password nulla = lascia la password com'è; vuota = la toglie
create or replace function public.password_salva(
  p_id bigint, p_servizio text, p_categoria text, p_url text, p_username text, p_password text, p_note text
) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id bigint;
  v_cat text := coalesce(nullif(btrim(p_categoria), ''), 'Altro');
begin
  if auth.uid() is null or not public.team_is_member() then raise exception 'Accesso non consentito'; end if;
  if coalesce(btrim(p_servizio), '') = '' then raise exception 'Il nome del servizio è obbligatorio'; end if;
  if p_id is null then
    insert into public.credenziali (servizio, categoria, url, username, pw_cifrata, note, created_by, updated_by)
    values (btrim(p_servizio), v_cat, nullif(btrim(p_url), ''), nullif(btrim(p_username), ''),
            case when coalesce(p_password, '') = '' then null else extensions.pgp_sym_encrypt(p_password, public.password_key()) end,
            nullif(btrim(p_note), ''), auth.uid(), auth.uid())
    returning id into v_id;
    insert into public.password_log (user_id, credenziale_id, servizio, azione) values (auth.uid(), v_id, btrim(p_servizio), 'crea');
  else
    update public.credenziali set
      servizio = btrim(p_servizio), categoria = v_cat, url = nullif(btrim(p_url), ''), username = nullif(btrim(p_username), ''),
      pw_cifrata = case when p_password is null then pw_cifrata
                        when p_password = '' then null
                        else extensions.pgp_sym_encrypt(p_password, public.password_key()) end,
      note = nullif(btrim(p_note), ''), updated_by = auth.uid(), updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Credenziale non trovata'; end if;
    insert into public.password_log (user_id, credenziale_id, servizio, azione) values (auth.uid(), v_id, btrim(p_servizio), 'modifica');
  end if;
  return v_id;
end $$;

-- apre una password: la decifra e lascia traccia
create or replace function public.password_rivela(p_id bigint) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_c public.credenziali;
begin
  if auth.uid() is null or not public.team_is_member() then raise exception 'Accesso non consentito'; end if;
  select * into v_c from public.credenziali where id = p_id;
  if not found then raise exception 'Credenziale non trovata'; end if;
  insert into public.password_log (user_id, credenziale_id, servizio, azione) values (auth.uid(), v_c.id, v_c.servizio, 'visto');
  if v_c.pw_cifrata is null then return ''; end if;
  return extensions.pgp_sym_decrypt(v_c.pw_cifrata, public.password_key());
end $$;

-- traccia anche le eliminazioni
create or replace function public.password_log_elimina() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.password_log (user_id, credenziale_id, servizio, azione) values (auth.uid(), old.id, old.servizio, 'elimina');
  return old;
end $$;
drop trigger if exists credenziali_elimina_log on public.credenziali;
create trigger credenziali_elimina_log after delete on public.credenziali for each row execute function public.password_log_elimina();

revoke all on function public.password_salva(bigint, text, text, text, text, text, text) from public, anon;
revoke all on function public.password_rivela(bigint) from public, anon;
grant execute on function public.password_salva(bigint, text, text, text, text, text, text) to authenticated;
grant execute on function public.password_rivela(bigint) to authenticated;

-- Online: canale Realtime privato, solo per la squadra (se il progetto non ha ancora realtime.messages, si salta)
do $$
begin
  if to_regclass('realtime.messages') is not null then
    execute 'drop policy if exists "suite online: leggere" on realtime.messages';
    execute 'create policy "suite online: leggere" on realtime.messages for select to authenticated using (realtime.messages.extension = ''presence'' and realtime.topic() = ''suite-online'' and public.team_is_member())';
    execute 'drop policy if exists "suite online: scrivere" on realtime.messages';
    execute 'create policy "suite online: scrivere" on realtime.messages for insert to authenticated with check (realtime.messages.extension = ''presence'' and realtime.topic() = ''suite-online'' and public.team_is_member())';
  end if;
end $$;
