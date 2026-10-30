-- Ricerca lead da Outbound (già applicata sul progetto Supabase "Lead Flowline").
-- Outbound inserisce una riga in lead_searches → il trigger chiama il webhook n8n
-- "Ricerca lead da Outbound" → n8n cerca su Google Maps con Apify e salva in public.leads.
--
-- Segreti nel Vault (non in questo file):
--   lead_search_webhook_url  = https://leo98.app.n8n.cloud/webhook/flowline-ricerca-lead
--   lead_search_webhook_key  = chiave condivisa, la stessa controllata dal webhook n8n (header x-flowline-key)
-- Per cambiarli: select vault.update_secret(id, 'nuovo valore') from vault.secrets where name = '...';

create table if not exists public.lead_searches (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text,
  params jsonb not null,
  status text not null default 'queued' check (status in ('queued','running','done','error')),
  apify_run_id text,
  found int,
  inserted int,
  duplicates int,
  skipped int,
  error text,
  started_at timestamptz,
  finished_at timestamptz
);
create index if not exists lead_searches_created_idx on public.lead_searches (created_at desc);
alter table public.lead_searches enable row level security;

drop policy if exists lead_searches_select on public.lead_searches;
create policy lead_searches_select on public.lead_searches for select to authenticated using (public.newsletter_is_editor());
drop policy if exists lead_searches_insert on public.lead_searches;
create policy lead_searches_insert on public.lead_searches for insert to authenticated with check (public.newsletter_is_editor());
drop policy if exists lead_searches_delete on public.lead_searches;
create policy lead_searches_delete on public.lead_searches for delete to authenticated using (public.newsletter_is_editor() and status in ('done','error'));
grant select, insert, delete on public.lead_searches to authenticated;

alter table public.leads add column if not exists search_id uuid references public.lead_searches(id) on delete set null;
alter table public.leads add column if not exists telefono text;
alter table public.leads add column if not exists fonte text;
alter table public.leads add column if not exists email_fonte text;
alter table public.leads add column if not exists importato_il timestamptz;
alter table public.leads add column if not exists created_at timestamptz;
update public.leads set created_at = coalesce(updated_at, now()) where created_at is null;
alter table public.leads alter column created_at set default now();
create index if not exists leads_search_idx on public.leads (search_id);

create or replace function public.lead_searches_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  p jsonb := new.params;
  n_cat int; n_luoghi int; per int; mx int;
begin
  if jsonb_typeof(p) <> 'object' then raise exception 'Parametri della ricerca non validi'; end if;
  if jsonb_typeof(p->'categorie') <> 'array' then raise exception 'Scegli almeno una categoria'; end if;
  n_cat := jsonb_array_length(p->'categorie');
  n_luoghi := case when jsonb_typeof(p->'luoghi') = 'array' then jsonb_array_length(p->'luoghi') else 0 end;
  if n_cat < 1 or n_cat > 10 then raise exception 'Scegli da 1 a 10 categorie'; end if;
  if n_luoghi > 20 then raise exception 'Massimo 20 province o città per ricerca'; end if;
  if coalesce(p->>'regione','') = '' and n_luoghi = 0 then raise exception 'Scegli una regione o almeno una città'; end if;
  if n_cat * greatest(n_luoghi,1) > 40 then raise exception 'Troppe combinazioni (% categorie × % luoghi): massimo 40 ricerche', n_cat, greatest(n_luoghi,1); end if;
  per := coalesce((p->>'per_ricerca')::int, 20);
  mx := coalesce((p->>'max_lead')::int, 50);
  if per < 5 or per > 100 then raise exception 'Risultati per ricerca: da 5 a 100'; end if;
  if mx < 1 or mx > 300 then raise exception 'Lead da salvare: da 1 a 300'; end if;
  if exists (select 1 from public.lead_searches where status in ('queued','running') and created_at > now() - interval '60 minutes') then
    raise exception 'C''è già una ricerca in corso: aspetta che finisca';
  end if;
  new.id := gen_random_uuid();
  new.created_at := now();
  new.created_by := coalesce(auth.jwt()->>'email', new.created_by);
  new.status := 'queued';
  new.apify_run_id := null; new.found := null; new.inserted := null; new.duplicates := null; new.skipped := null;
  new.error := null; new.started_at := null; new.finished_at := null;
  return new;
end $$;
drop trigger if exists lead_searches_bi on public.lead_searches;
create trigger lead_searches_bi before insert on public.lead_searches for each row execute function public.lead_searches_before_insert();

create or replace function public.lead_searches_notify()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  hook text; k text;
begin
  select decrypted_secret into hook from vault.decrypted_secrets where name = 'lead_search_webhook_url';
  select decrypted_secret into k from vault.decrypted_secrets where name = 'lead_search_webhook_key';
  if hook is null or k is null then
    update public.lead_searches set status = 'error', error = 'Webhook n8n non configurato', finished_at = now() where id = new.id;
    return new;
  end if;
  perform net.http_post(
    url := hook,
    body := jsonb_build_object('search_id', new.id),
    headers := jsonb_build_object('Content-Type','application/json','x-flowline-key', k),
    timeout_milliseconds := 10000
  );
  return new;
end $$;
drop trigger if exists lead_searches_ai on public.lead_searches;
create trigger lead_searches_ai after insert on public.lead_searches for each row execute function public.lead_searches_notify();

revoke all on function public.lead_searches_before_insert() from public, anon, authenticated;
revoke all on function public.lead_searches_notify() from public, anon, authenticated;
