-- Contabilità: movimenti importati da PayPal.
-- Il flusso n8n "PayPal → Contabilità FlowLine" li salva con stato "da_verificare": non contano nel saldo
-- finché non vengono confermati dalla suite. esterno_id (ID PayPal) è unico, così lo stesso movimento
-- non viene mai importato due volte. Da eseguire dopo 20261103190000_contabilita.sql.

alter table public.movimenti add column if not exists origine text not null default 'manuale';
alter table public.movimenti add column if not exists esterno_id text;

create unique index if not exists movimenti_esterno_id_key on public.movimenti (esterno_id);

alter table public.movimenti drop constraint if exists movimenti_stato_check;
alter table public.movimenti add constraint movimenti_stato_check
  check (stato in ('completato','in_corso','in_sospeso','da_verificare'));
