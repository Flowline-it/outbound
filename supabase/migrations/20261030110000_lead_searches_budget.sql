-- Ricerca lead v2 (già applicata): obiettivo di lead + tetto di spesa, una zona alla volta.
-- Il webhook ora è https://leo98.app.n8n.cloud/webhook/flowline-ricerca-lead-v2 (segreto lead_search_webhook_url nel Vault).
alter table public.lead_searches add column if not exists spent_usd numeric not null default 0;
alter table public.lead_searches add column if not exists zone_done int not null default 0;
alter table public.lead_searches add column if not exists plan jsonb;
alter table public.lead_searches add column if not exists runs jsonb not null default '[]'::jsonb;
alter table public.lead_searches add column if not exists note text;

create or replace function public.lead_searches_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  p jsonb := new.params;
  n_cat int; n_prov int; n_altri int; tgt int; bud numeric;
begin
  if jsonb_typeof(p) <> 'object' then raise exception 'Parametri della ricerca non validi'; end if;
  if jsonb_typeof(p->'categorie') <> 'array' then raise exception 'Scegli almeno una categoria'; end if;
  n_cat := jsonb_array_length(p->'categorie');
  n_prov := case when jsonb_typeof(p->'province') = 'array' then jsonb_array_length(p->'province') else 0 end;
  n_altri := case when jsonb_typeof(p->'altri') = 'array' then jsonb_array_length(p->'altri') else 0 end;
  if n_cat < 1 or n_cat > 10 then raise exception 'Scegli da 1 a 10 categorie'; end if;
  if n_prov > 20 then raise exception 'Massimo 20 province per ricerca'; end if;
  if n_altri > 10 then raise exception 'Massimo 10 città o zone scritte a mano'; end if;
  if coalesce(p->>'regione','') = '' and n_altri = 0 then raise exception 'Scegli una regione o almeno una città'; end if;
  tgt := coalesce((p->>'target')::int, 0);
  bud := coalesce((p->>'budget_usd')::numeric, 0);
  if tgt < 5 or tgt > 200 then raise exception 'Lead da trovare: da 5 a 200'; end if;
  if bud < 0.1 or bud > 5 then raise exception 'Tetto di spesa: da 0,10 a 5 dollari'; end if;
  if exists (select 1 from public.lead_searches where status in ('queued','running') and created_at > now() - interval '90 minutes') then
    raise exception 'C''è già una ricerca in corso: aspetta che finisca';
  end if;
  new.id := gen_random_uuid();
  new.created_at := now();
  new.created_by := coalesce(auth.jwt()->>'email', new.created_by);
  new.status := 'queued';
  new.apify_run_id := null; new.found := null; new.inserted := null; new.duplicates := null; new.skipped := null;
  new.error := null; new.started_at := null; new.finished_at := null;
  new.spent_usd := 0; new.zone_done := 0; new.plan := null; new.runs := '[]'::jsonb; new.note := null;
  return new;
end $$;
revoke all on function public.lead_searches_before_insert() from public, anon, authenticated;
