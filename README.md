# FlowLine Suite

Strumenti interni di Flowline in un'unica pagina (`index.html`), pubblicata con GitHub Pages.

## Aree

**Outbound**: campagne email a freddo.
- Dashboard: partenze di oggi, risposte, carico della settimana
- Ricerca lead: ricerche su Google Maps (Apify, tramite il flusso n8n "Ricerca lead da Outbound") con obiettivo di lead e tetto di spesa
- Contatti: elenco con filtri, selezione multipla ed eliminazione in blocco
- Pianificazione, Coda invio, Calendario, Risposte: sequenza di email da Gmail

**Newsletter**: iscritti dal sito flowline.it, scrittura e invio da Gmail, statistiche anonime di aperture e clic.

**Richieste**: chi compila "Prenota la consulenza gratuita" su flowline.it. Elenco con ricerca e filtri, scheda con email e telefono, stato (Nuova, Contattata, In trattativa, Cliente, Archiviata), note interne, importazione ed esportazione CSV, eliminazione per le richieste di cancellazione dei dati.

## Dati

Database Supabase "Lead Flowline": `contacts`, `leads`, `lead_searches`, tabelle `newsletter_*`, `richieste_sito`.
Il form del sito scrive in `richieste_sito` solo con la funzione `richiesta_sito_invia`; Newsletter, Ricerca lead e Richieste si leggono dopo il login di un indirizzo presente in `newsletter_editors`.
Le migrazioni e la funzione `nl-track` sono in `supabase/`.
