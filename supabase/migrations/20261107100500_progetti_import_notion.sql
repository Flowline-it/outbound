-- FlowLine Suite: importazione una tantum da Notion (7 novembre 2026).
-- Progetti dal database «📁 Progetti» e attività aperte dal «Database task».
-- Le attività già completate in Notion non vengono copiate una per una: restano come conteggio (completate_notion).
-- Richiede 20261107100000_progetti_attivita.sql. Si può rieseguire: chi c'è già (stesso notion_id) non viene toccato.
-- Le persone si trovano per nome in team_members (Leonardo, Giacomo, Pietro, Giuseppe): se il nome è diverso, l'attività resta senza persona.

create or replace function public._import_persone(p text[])
returns uuid[] language sql stable set search_path = public as $$
  select coalesce(array_agg(t.id), '{}') from public.team_members t
  where exists (select 1 from unnest(p) x where lower(t.nome) like x || '%' or lower(t.email) like '%' || x || '%')
$$;

insert into public.progetti (notion_id, nome, cliente, stato, urgente, inizio, link, persone, drive_id, drive_nome, drive_percorso, drive_cartelle, completate_notion) values
  ('35fcdcc112af80aca9f9cb619bc4a2b4', 'Gestionale personalizzato (ex magazzino)', 'Perfettibile S.r.l.', 'assistenza', true, '2026-05-26'::date, null, public._import_persone(array['pietro','giacomo']::text[]), '1vCP1BdgjrKpH1VhlFBpVJlnHOPci44uT', 'Perfettibile S.r.l.', 'Drive condiviso › Progetti', '[{"n": "Contratto firmato", "id": "1G7ZCjWO3PSqym0QRmFTjZRfpyaHu3L8k"}, {"n": "Appunti riunioni - Perfettibile S.r.l.", "id": "1m-iE4l-9GuErLJHbw8O2OdKrUmMUSiOi"}]'::jsonb, 184),
  ('3e9cdcc112af8060b33cf9451209bb66', 'Sistema generazione preventivi', 'Impresa edile Baldo Paolo & C.', 'attivo', true, '2026-09-16'::date, 'https://edilbaldo-preventivi.flat-river-a1b4.workers.dev/', public._import_persone(array['pietro','giacomo','leonardo']::text[]), '19EU8wCCPKy4jZ9Gh_KKYGbh4utLgJ0I6', 'Impresa edile Baldo Paolo S.n.c.', 'Drive condiviso › Progetti', '[{"n": "Edilbaldo - Preventivi Digitali", "id": "1a_xvAdJzMWfYGY8L4ViQcpqy4tGhcSPj"}, {"n": "Edilbaldo - Template", "id": "1az875RJfQARHteq2kH5U7UuoJXeKtfZD"}, {"n": "Elementi vari Impresa edile Baldo Paolo", "id": "1ukBZvCIixj5w5ebjDb4vhi8xTrXlujTA"}]'::jsonb, 9),
  ('374cdcc112af804fbfdcee9b72086000', 'Chatbot WhatsApp', 'Flowline (interno)', 'attivo', true, null, null, public._import_persone(array['leonardo','giuseppe']::text[]), '1CZJzrFKvVrRpvBXSM110-IAqacaIkBrr', 'Chatbot WhatsApp', 'Drive condiviso › Progetti', '[]'::jsonb, 35),
  ('366cdcc112af80f3bb9dc22c962dea89', 'Ricerca clienti internazionali', 'GEARXPro', 'attivo', true, null, null, public._import_persone(array['giuseppe','giacomo']::text[]), '1aH3BfgyhpfmDGWznvyN7koQ5Y-mJrJdC', 'GEARXPro', 'Drive condiviso › Progetti', '[{"n": "Appunti riunioni - GearSPRO", "id": "1Mqngx8yVTwVoeptQIsVnwPrwV6wHZA0t"}]'::jsonb, 5),
  ('3dfcdcc112af803c9020d59efc1f9092', 'Gestionale appuntamenti saloni e parrucchieri', 'Salone Anna', 'attivo', true, '2026-09-01'::date, null, public._import_persone(array['pietro']::text[]), '1cv14CAW-ESTnbl-lT87VKwoFVbkYVylm', 'Salone Anna', 'Drive condiviso › Progetti', '[]'::jsonb, 1),
  ('3dbcdcc112af80ceb57bf52038897e39', 'Flusso Marketing', 'Flowline (interno)', 'attivo', false, null, null, public._import_persone(array['leonardo','pietro','giuseppe']::text[]), '1h1uiJJiC7_XSyEBiB4UDpCRAm8ERlkcM', 'Marketing', 'Drive condiviso', '[{"n": "Caroselli", "id": "1wLY7H7bRZbtb2o5eVhEgNKxyyGRyfaht"}, {"n": "Quote Card", "id": "1lYdIoSo8MwekfIE5z_CIeMud3AobvUuY"}]'::jsonb, 12),
  ('374cdcc112af80aaa2cdfda070ff3d51', 'Automazioni contabilità', 'Studio Rigotto', 'attivo', false, null, null, public._import_persone(array['pietro','giacomo','leonardo']::text[]), '16kNtU0XGRPULFHGLkYDS0S6g7jAWpuUw', 'Studio Rigotto', 'Drive condiviso › Progetti', '[]'::jsonb, 0),
  ('30dcdcc112af8063b85ecbf23ed222d5', 'Automazione Email Marketing', 'Flowline (interno)', 'attivo', false, null, null, '{}'::uuid[], null, null, null, '[]'::jsonb, 0),
  ('408cdcc112af80f4839cf3637e519a56', 'Sito web Flowline', 'Flowline (interno)', 'attivo', false, null, null, public._import_persone(array['giuseppe']::text[]), null, null, null, '[]'::jsonb, 2),
  ('3b6cdcc112af803ab0b6cf8e5db54bf4', 'Embrione gestionale', 'Termoidraulica Gibboni S.r.l.', 'demo', false, '2026-08-04'::date, null, public._import_persone(array['pietro','giacomo']::text[]), '1hvKo_GqnpI5Z_Tbhke0dy0YZBsFVecF5', 'Termoidraulica Gibboni S.r.l.', 'Drive condiviso › Progetti', '[{"n": "Materiali Termoidraulica Gibboni", "id": "1-YMl94JLzzLZGtgwk1jGrtULNXIRedEb"}, {"n": "Webapp", "id": "1xMFMsHsCnKQ10wUZ40Rqb-oVYpT_LAFC"}]'::jsonb, 1),
  ('401cdcc112af802eada5d5b8146d446d', 'Progetto ALMAtech', 'ALMAtech S.r.l.', 'demo', false, '2026-09-29'::date, null, public._import_persone(array['giuseppe']::text[]), '1aANw8MvmS1fnTq8czEJaoEL6_kOZSIF8', 'Almatech srl', 'Drive condiviso › Progetti', '[{"n": "Flowline x Almatech SRL - 2026/09/29", "id": "1243z7unQN4mDV8Rr2deNK6rpClv8G9Qh"}]'::jsonb, 0),
  ('401cdcc112af8074aa06d4d2c622491a', 'Calcolatore costi di gestione', 'Vigneti Pittaro', 'demo', false, '2026-10-20'::date, null, public._import_persone(array['pietro','giacomo']::text[]), null, null, null, '[]'::jsonb, 0),
  ('2e1cdcc112af8095b644ebb6e2cffc60', 'Lead Generator – Callforus', 'Callforus', 'pausa', false, null, null, '{}'::uuid[], null, null, null, '[]'::jsonb, 0),
  ('366cdcc112af80049366ce145b49ec0b', 'Ricerca clienti Grafì', 'Grafì Comunicazione', 'chiuso', false, null, null, '{}'::uuid[], '1vFeovnJJe2Xzwz2Bu4e8pfp-L2D3rSEw', 'Grafì Comunicazione - Ricerca clienti', 'Drive condiviso › Progetti › Paolo Mason', '[]'::jsonb, 0),
  ('396cdcc112af803db6c5cabaf3c828f0', 'Incontri formativi Confartigianato', 'Confartigianato del Veneto Orientale', 'chiuso', false, null, null, public._import_persone(array['giuseppe','pietro','giacomo']::text[]), '1t7iNcaLutuayBUolxIahIDNnxUfV_XtQ', 'Incontri formativi Confartigianato', 'Drive condiviso', '[{"n": "Video e foto secondo incontro formativo Confartigianato", "id": "1JMOwc4nUYAhcsOMYk--wY-lp5vI1lGc4"}]'::jsonb, 5),
  ('3b3cdcc112af80ebb3aacfa4544a6899', 'Assistente tecnico ascensori', 'Alicron S.r.l.', 'chiuso', false, null, null, public._import_persone(array['leonardo','giacomo','pietro']::text[]), '1MripQe_2pB-1fH6qH_ZI_Ni1yrxPjW5a', 'Alicron S.r.l.', 'Drive condiviso › Progetti', '[{"n": "MANUALI", "id": "1iii5Eg2D5eh2dJVbWXdho-QCnNMz5_aA"}, {"n": "Preventivi e contratti - Alicron S.r.l.", "id": "1L5aMNVQRuIRg_UNhr-6APOXIAERzrFhO"}]'::jsonb, 5),
  ('3b4cdcc112af804b952dd363f741e972', 'Estrazione preventivi fornitori', 'Alicron S.r.l.', 'chiuso', false, null, null, public._import_persone(array['pietro','giacomo','leonardo']::text[]), '1MripQe_2pB-1fH6qH_ZI_Ni1yrxPjW5a', 'Alicron S.r.l.', 'Drive condiviso › Progetti', '[{"n": "Preventivi e contratti - Alicron S.r.l.", "id": "1L5aMNVQRuIRg_UNhr-6APOXIAERzrFhO"}]'::jsonb, 0),
  ('330cdcc112af8045a226ccd1f3e5c1d8', 'Eventuali automazioni future Panificio Zani', 'Forno Zani', 'chiuso', false, null, null, '{}'::uuid[], '1TQ8iAsDiSdeZazzZrR6HNzL12eSVgbBE', 'Forno Zani', 'Drive condiviso › Progetti', '[]'::jsonb, 0)
on conflict (notion_id) where notion_id is not null do nothing;

insert into public.attivita (notion_id, progetto_id, titolo, stato, persone, urgente, note)
select v.nid, p.id, v.titolo, v.stato, v.persone, v.urgente, v.note
from (values
  ('3c8cdcc112af80dc8c40c24190fd7ae9', '374cdcc112af804fbfdcee9b72086000', 'Configurazione account Facebook', 'in_corso', public._import_persone(array['leonardo']::text[]), false, null),
  ('3aacdcc112af808385afd5cff23b853f', '374cdcc112af804fbfdcee9b72086000', 'Creare landing page per vendita', 'in_corso', public._import_persone(array['giuseppe']::text[]), false, null),
  ('395cdcc112af8032baa5f1d9cb28e43c', '374cdcc112af804fbfdcee9b72086000', 'Configurazione Tech Provider', 'da_fare', public._import_persone(array['leonardo','giuseppe']::text[]), false, null),
  ('3aacdcc112af8059865dd0b479b39ad4', '374cdcc112af804fbfdcee9b72086000', 'Studiare nuove funzioni per il chatbot', 'da_fare', public._import_persone(array['leonardo','giuseppe']::text[]), false, null),
  ('3aacdcc112af80c6a3c1ffd6374f3ef1', '374cdcc112af804fbfdcee9b72086000', 'Preventivi per il lancio del prodotto', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('3aacdcc112af80f1bdf9f07d76cf7766', '374cdcc112af804fbfdcee9b72086000', 'Attivare modalità di pagamento', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('3a0cdcc112af805794acc23a502fbed1', '374cdcc112af804fbfdcee9b72086000', 'Modifiche a prezzi, servizi e prodotti via chat', 'in_attesa', public._import_persone(array['leonardo']::text[]), true, 'Il titolare deve avere la possibilità di modificare tramite chat questi parametri.'),
  ('374cdcc112af81d88764f2e6ef755189', '374cdcc112af804fbfdcee9b72086000', 'GDPR & sistema feedback', 'in_attesa', public._import_persone(array['leonardo']::text[]), false, null),
  ('374cdcc112af8158bde0e79d7a6f0529', '374cdcc112af804fbfdcee9b72086000', 'Dashboard di monitoraggio', 'in_attesa', public._import_persone(array['leonardo']::text[]), false, null),
  ('374cdcc112af81d08bffeb0e2e08ac9b', '374cdcc112af804fbfdcee9b72086000', 'Trascrizione vocale migliorata', 'in_attesa', public._import_persone(array['leonardo']::text[]), false, null),
  ('380cdcc112af81fa8272ebbe417532ca', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Tracciabilità delle modifiche alle date di arrivo', 'in_corso', public._import_persone(array['pietro','giacomo']::text[]), false, 'Le modifiche alle date di arrivo dei prodotti devono essere tracciabili, insieme agli operatori che le fanno.'),
  ('3adcdcc112af8061a944d3254e2e9118', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Verificare la notifica di apertura nuova distinta base in n8n (flusso “Post Ordine Submit”)', 'in_corso', public._import_persone(array['giacomo']::text[]), false, null),
  ('3a8cdcc112af809db8f4d9e4ee345524', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Test allegati nelle email', 'in_corso', public._import_persone(array['pietro']::text[]), false, 'In Notion era «Da verificare».'),
  ('380cdcc112af8113893bd64ee03e7aaf', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Documento di consuntivo costi a fine commessa', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, 'Alla fine di ogni commessa va creato un documento di consuntivo dei costi della singola commessa.'),
  ('380cdcc112af81a69b69e072adec0e9b', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Generare un DDT per le uscite di magazzino verso l’esterno', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('380cdcc112af81ccbcb4c74d24094076', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Promemoria a 2 settimane dal DDT + email di feedback', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('380cdcc112af8168bda6e6237c5361c9', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Dismettere il webhook GET /scelta-fornitore', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('3eccdcc112af806f8326f864f5e364b8', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Decidere come gestire i nomi dei componenti scritti in modo impreciso', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('380cdcc112af8110aff6d0862f2d7054', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Centralizzare l’anagrafica Operatori', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('380cdcc112af819ca4f0c66011bc7591', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Hardening RLS sulle tabelle Supabase', 'da_fare', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('3a8cdcc112af8052aab9e0225ef67f09', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Test della sezione “Nuova distinta base”', 'da_fare', public._import_persone(array['pietro']::text[]), false, null),
  ('3a8cdcc112af80a19fb3cd94af2575da', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Test notifiche distinta base', 'da_fare', public._import_persone(array['pietro']::text[]), false, null),
  ('3a8cdcc112af80b6a3ffc9d98d5fb39a', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Test E2E — Invio Richiesta di Preventivo (RDP)', 'da_fare', public._import_persone(array['pietro']::text[]), false, null),
  ('3cdcdcc112af8039bebbd31bfc3cd78c', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Sistemare l’anteprima PDF del DDT “Conto terzi”', 'da_fare', public._import_persone(array['pietro']::text[]), false, 'Le due anteprime sono diverse: quella corretta è quella di «Cliente finale».'),
  ('3f8cdcc112af8070a486e6b4103addad', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Aggiungere i certificati ai lotti nella sezione “Giacenza”', 'da_fare', public._import_persone(array['pietro']::text[]), false, null),
  ('405cdcc112af80c28c3de1e566d192e4', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Numerazione progressiva per gli arrivi delle merci', 'da_fare', public._import_persone(array['pietro']::text[]), false, 'Serve per tenere traccia della merce arrivata.'),
  ('3fecdcc112af80e5a05fffab15ac7333', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Attivare il database una volta a settimana per evitare che Supabase si spenga', 'da_fare', public._import_persone(array['pietro']::text[]), false, null),
  ('380cdcc112af81858c19dde1b9f109f6', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Sezione preventivi separata per i clienti finali', 'in_attesa', public._import_persone(array['pietro','giacomo']::text[]), true, null),
  ('3c1cdcc112af808bbcccfde7233a8016', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Modificare la sezione “Ordini acquisto”', 'in_attesa', public._import_persone(array['pietro']::text[]), false, null),
  ('3f1cdcc112af803e9947fd38854c6515', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Creare una distinta base a partire da un file Excel', 'in_attesa', public._import_persone(array['pietro','giacomo']::text[]), false, null),
  ('405cdcc112af80eda223fdcafefa7acf', '35fcdcc112af80aca9f9cb619bc4a2b4', 'Correggere il problema legato ai macrogruppi', 'in_attesa', public._import_persone(array['pietro']::text[]), false, null),
  ('401cdcc112af8035803cd11ecf0de559', '3e9cdcc112af8060b33cf9451209bb66', 'Inserire il documento di sicurezza (POS) nella webapp', 'in_attesa', public._import_persone(array['leonardo']::text[]), false, 'Edilbaldo deve fornirci una copia del documento di sicurezza.'),
  ('3dbcdcc112af80da965ad8bd04f8b213', '3dbcdcc112af80ceb57bf52038897e39', 'Abbozzare struttura flusso', 'in_corso', public._import_persone(array['leonardo','pietro']::text[]), false, null),
  ('408cdcc112af805ca1a5e6e5156cfc33', '3dbcdcc112af80ceb57bf52038897e39', 'Migliorare le fonti', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('408cdcc112af800f9498dc87765b2924', '3dbcdcc112af80ceb57bf52038897e39', 'Sblocco dei commenti', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('408cdcc112af8071a46fddabf2df49cc', '3dbcdcc112af80ceb57bf52038897e39', 'Renderlo 100% automatico', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('408cdcc112af80f38370e33c1ccca76d', '408cdcc112af80f4839cf3637e519a56', 'Versione in inglese', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('408cdcc112af8009a9d8e001224d105d', '408cdcc112af80f4839cf3637e519a56', 'Applicare audit', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('408cdcc112af8069a828d4f4c7c727cf', '408cdcc112af80f4839cf3637e519a56', 'Inserire iscrizione newsletter', 'da_fare', public._import_persone(array['giuseppe']::text[]), false, null),
  ('401cdcc112af801f8d4bc3a9265df8ab', '401cdcc112af8074aa06d4d2c622491a', 'Preparare una demo di un gestionale dei costi', 'da_fare', public._import_persone(array['pietro']::text[]), false, null)
) as v(nid, pnid, titolo, stato, persone, urgente, note)
join public.progetti p on p.notion_id = v.pnid
on conflict (notion_id) where notion_id is not null do nothing;

drop function public._import_persone(text[]);

-- Controllo: quanti progetti e attività aperte ci sono adesso
select (select count(*) from public.progetti) as progetti, (select count(*) from public.attivita where stato <> 'fatto') as attivita_aperte;
