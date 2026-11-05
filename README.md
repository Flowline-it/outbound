# FlowLine Suite

Strumenti interni di Flowline in un'unica pagina (`index.html`), pubblicata con GitHub Pages.

## Aree

**Home**: la prima pagina dopo l'accesso, con scorciatoie a ciò che serve oggi.
- Call di oggi (dal Calendario), email da inviare oggi divise in prima email, follow-up 1 e follow-up 2, saldo del conto aziendale, iscritti alla newsletter, nuove risposte alle email
- Ogni scheda porta alla sezione corrispondente. Nelle call di oggi, un clic sulla call apre il link della chiamata (Meet) e l'ingranaggio accanto apre le impostazioni dell'evento; se la call non ha un link, il clic apre i dettagli
- Online: chi della squadra è nella Suite in questo momento (in alto accanto alla campanella e nella Home), con la sezione in cui si trova; chi ha la scheda in secondo piano risulta «non attivo»
- Messaggi: scambio di messaggi personali tra collaboratori, visibili solo ai due interessati; chi riceve vede una notifica nella campanella. Si può cancellare solo il proprio messaggio
- Bacheca: comunicazioni per tutta la squadra, con titolo facoltativo e possibilità di metterle in evidenza. Ognuno modifica, mette in evidenza ed elimina solo le proprie; tutti ricevono una notifica quando ne esce una nuova
- Serve la migrazione `20261104150000_messaggi_bacheca.sql` (dopo quella del Calendario)

**Outbound**: campagne email a freddo.
- Dashboard: partenze di oggi, risposte, carico della settimana
- Ricerca lead: ricerche su Google Maps (Apify, tramite il flusso n8n "Ricerca lead da Outbound") con obiettivo di lead e tetto di spesa
- Contatti: elenco con filtri, selezione multipla ed eliminazione in blocco
- Pianificazione, Coda invio, Piano invii, Risposte: sequenza di email da Gmail

**Newsletter**: iscritti dal sito flowline.it, scrittura e invio da Gmail, statistiche anonime di aperture e clic.

**Richieste**: chi compila "Prenota la consulenza gratuita" su flowline.it. Elenco con ricerca e filtri, scheda con email e telefono, stato (Nuova, Contattata, In trattativa, Cliente, Archiviata), note interne, importazione ed esportazione CSV, eliminazione per le richieste di cancellazione dei dati.

**Contabilità**: conti e movimenti dell'azienda, al posto della sezione Contabilità di Notion.
- Panoramica: saldo del conto aziendale calcolato in tempo reale, entrate e uscite del mese, ultimi sei mesi, movimenti da completare
- Movimenti: elenco con ricerca e filtri (conto, tipo, categoria, mese, stato), aggiunta e modifica, esportazione CSV
- Conti: saldo iniziale e «Allinea al saldo reale» per far coincidere il saldo con quello della banca
- Report: entrate e uscite per anno, mese e categoria
- Il saldo non è salvato: saldo iniziale + ciò che entra - ciò che esce. Contano solo i movimenti completati (si può cambiare)
- Al primo avvio, «Importa i dati di Notion» carica conti e movimenti di partenza
- I movimenti arrivano anche da PayPal: il flusso n8n «PayPal → Contabilità FlowLine» li salva «Da verificare» (non contano nel saldo) e si confermano uno a uno o tutti insieme
- Le quote ai soci (soldi dal conto aziendale al conto personale di un socio) sono una ripartizione degli utili, non un costo: hanno il tipo «Quota ai soci», una voce a parte in panoramica, grafico e report, e restano fuori dalle uscite. Nel database sono trasferimenti (`tipo = move`) dal conto aziendale a un socio; le vecchie righe «uscita» con categoria Stipendio/Quota verso un socio vengono lette come quote

**Calendario**: agenda condivisa del team con notifiche.
- Accesso personale per Giuseppe, Giacomo, Leonardo e Pietro (Supabase Auth), uguale per tutte le aree. Tutti hanno gli stessi permessi
- Vista settimana e mese, filtri per persona e per calendario, nuovo evento con partecipanti ben visibili (call, appuntamento, impegno, altro)
- Calendario «azienda» (sincronizzato con Google Calendar `info@flowline.it`) e calendario «personale» (non va mai su Google)
- Campanella: un clic apre l'anteprima delle ultime notifiche; un clic su una notifica la segna come letta e apre l'evento nella settimana giusta
- Notifiche in app: aggiunto a un evento, evento spostato, modificato o annullato. Le crea solo il database, il client non può scriverle. Le email si potranno aggiungere in seguito (`notifiche.email_stato`)
- Task e Progetti: la struttura è già pronta (`notifiche.rif_tipo/rif_id`, `eventi.progetto_id`), le sezioni non ci sono ancora
- Sincronizzazione con Google, due flussi n8n: «Calendario: Google → Suite» (ogni 5 minuti; crea e aggiorna eventi, annulla quelli cancellati, aggiunge i partecipanti) e «Calendario: Suite → Google» (webhook; crea, aggiorna ed elimina su Google senza inviare email di invito). Gli ospiti esterni indicati nell'evento diventano invitati su Google. Se una persona su Google ha un indirizzo diverso da quello di accesso, si indica in `team_members.email_google`
- Messa in funzione: creare i quattro utenti in Authentication → Users, eseguire la migrazione `20261104100000_team_calendario_notifiche.sql`, poi per ciascuno `select public.team_aggiungi('email','Nome','#colore');` dal SQL Editor. Per la sincronizzazione servono due segreti in Vault, `calendar_webhook_url` (indirizzo del webhook n8n) e `calendar_webhook_key` (stessa chiave del flusso), e le credenziali Google sui tre nodi HTTP del flusso Suite → Google

**Password**: archivio delle credenziali di Flowline, al posto della pagina Password di Notion.
- Archivio: ricerca, filtro per categoria, aggiunta, modifica ed eliminazione; utente e password si copiano con un clic; la password si può mostrare (si nasconde da sola dopo 20 secondi); generatore di password casuali; importazione di un elenco incollato («servizio ; utente ; password ; sito ; note»)
- Le password sono cifrate nel database (pgcrypto, chiave casuale nel Vault di Supabase `password_archivio_key`, creata dalla migrazione): la tabella non le mostra mai e si aprono solo con la funzione `password_rivela`, riservata alla squadra. **Non cancellare né cambiare quel segreto**, altrimenti le password salvate non si aprono più. La cifratura protegge da fughe e accessi non autorizzati al database, ma chi amministra Supabase può leggere anche la chiave
- Registro accessi: chi ha aggiunto, modificato, eliminato o aperto quale credenziale, e quando (lo vede tutta la squadra)
- Serve la migrazione `20261105100000_password_online.sql`, che attiva anche le regole del canale privato «suite-online» usato da Online

## Dati

Database Supabase "Lead Flowline": `contacts`, `leads`, `lead_searches`, tabelle `newsletter_*`, `richieste_sito`, `conti`, `movimenti`, `team_members`, `eventi`, `evento_partecipanti`, `notifiche`, `messaggi`, `bacheca`, `credenziali`, `password_log`.
Il form del sito scrive in `richieste_sito` solo con la funzione `richiesta_sito_invia`; Newsletter, Ricerca lead, Richieste e Contabilità si leggono dopo il login di un indirizzo presente in `newsletter_editors`; Calendario richiede un utente in `team_members` (che viene aggiunto anche a `newsletter_editors`).
Le migrazioni e la funzione `nl-track` sono in `supabase/`.
