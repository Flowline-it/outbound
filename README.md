# FlowLine Suite

Strumenti interni di Flowline in un'unica pagina (`index.html`), pubblicata con GitHub Pages.

## Menu

**Home · Outbound · CRM · Marketing · Calendario · Progetti · Amministrazione · Impostazioni**

- Un clic su un'area apre il suo menu a tendina con le pagine. **Marketing** (Newsletter, Richieste) e **Amministrazione** (Contabilità, Password) hanno un sottomenu a cascata: a sinistra i moduli, a destra le pagine del modulo su cui passi. Su telefono il menu si apre a fisarmonica. Sotto il titolo restano le schede del modulo in cui sei.
- **Home personalizzabile**: «Personalizza» in alto nella Home. Si trascinano i riquadri (o si usano le frecce), si sceglie la dimensione (Piccolo, Medio, Grande, Largo, Riga intera) e si tolgono quelli che non servono (la × nell'angolo; i riquadri tolti restano in «Da aggiungere»). La × compare anche fuori da «Personalizza», passando sopra un riquadro, con «Annulla». Vale per la singola persona e si salva in `team_members.home_layout` (senza la migrazione `20261109200000_avvisi_email_home.sql` resta nel browser).
- **Cerca** (in alto, oppure Ctrl+K / ⌘K o il tasto «/»): una sola casella per trovare pagine della Suite, aziende, persone, preventivi e incontri del CRM, progetti, attività, comunicazioni della Bacheca, eventi del Calendario, contatti LinkedIn e di Outbound. Frecce per muoversi, Invio per aprire. Scrivendo «nuova…» propone anche le azioni (nuova attività, nuova azienda, nuovo incontro…). Cerca nei dati già caricati e all'apertura carica quelli che mancano.
- **Impostazioni** è una pagina con cinque schede: Generali (profilo, tema, modalità test), Collegamenti (Google con il mittente «Invia come» e la Google API key per il selettore di Drive, Anthropic, Supabase), Outbound (regole di invio, sequenza, firma e formato, testi AI), Newsletter (sito per la disiscrizione), Avanzate (SQL di setup, configurazione team, migrazione dal Google Sheet, spesa API, azzera tutto). Si salva con la barra «Salva» in fondo alla pagina.

## Avvisi via email

Quando qualcuno pubblica in **Bacheca**, tutta la squadra (tranne chi scrive) riceve una email. Quando qualcuno ti **aggiunge a un'attività** di Progetti, ricevi una email (a te stesso no). La mail ha un pulsante che apre la Bacheca o direttamente l'attività (`#bacheca`, `#attivita-123`), anche passando dall'accesso.

Come funziona: la migrazione `20261109200000_avvisi_email_home.sql` segna «da_inviare» le notifiche di tipo `bacheca` e `attivita_assegnata` e chiama il flusso n8n **«Suite: email di avviso»** (webhook `flowline-avvisi`, header `x-flowline-key`). Il flusso prende la notifica con `notifica_email_prendi` (una volta sola, niente doppioni), manda la mail con Gmail come «FlowLine Suite» e, se non parte, la segna «errore» con `notifica_email_errore`.

Messa in funzione:
1. SQL Editor → `20261109200000_avvisi_email_home.sql`
2. Vault, una volta sola (la chiave è la stessa scritta nel nodo «Controlla chiave» del flusso):
   `select vault.create_secret('https://leo98.app.n8n.cloud/webhook/flowline-avvisi', 'avvisi_webhook_url');`
   `select vault.create_secret('<chiave>', 'avvisi_webhook_key');`
3. n8n: flusso attivo, credenziali «Lead Flowline» (Postgres) e Gmail.

Senza Vault o senza flusso non si rompe niente: la campanella funziona come prima e le notifiche restano «da_inviare».

### Riepilogo delle attività (10 novembre)

Per non riempire la posta, le email sulle **attività assegnate** non partono più una per volta: vanno «in_coda» e un flusso n8n orario, **«Suite: riepilogo email delle attività»** (ogni ora al minuto 5), manda **una sola email a persona** con tutte le attività nuove, divise per progetto. Le comunicazioni della **Bacheca** continuano a partire subito.

- Ognuno sceglie come riceverle dal proprio profilo (clic sul nome in alto → «Il mio profilo»): riepilogo ogni 4 ore (predefinito), ogni 2 ore, uno al giorno la mattina, subito (una mail per attività) o nessuna. Colonna `team_members.avvisi_attivita`.
- Regole in `riepilogo_attivita_prepara()`: si manda solo tra le 8 e le 20 (ora italiana), di notte si accumula; l'ultima attività in coda deve avere almeno 10 minuti (così una serie di assegnazioni finisce nella stessa mail); non si manda ciò che nel frattempo è stato letto, completato o cancellato. Se Gmail rifiuta, le notifiche passano a «errore» (`riepilogo_attivita_errore`).
- Messa in funzione: eseguire `20261110180000_profilo_bacheca_riepilogo.sql`, poi **pubblicare** il flusso n8n (è creato spento). Il flusso «Suite: email di avviso» resta attivo per la Bacheca e per chi sceglie «subito».

## Foto profilo, categorie e scadenza della Bacheca (10 novembre)

- **Foto profilo**: dal profilo si carica un'immagine (JPG, PNG o WebP); la Suite la ritaglia in quadrato a 256 px e la salva nel bucket pubblico `avatars` di Supabase Storage, nella cartella con l'id della persona (`avatars/<id>/avatar.jpg`). Il link sta in `team_members.avatar_url`. Si vede ovunque ci sia l'iniziale colorata (calendario, progetti, Bacheca, Online).
- **Bacheca in cima**: il riquadro è il primo della Home di tutti (la migrazione lo porta in cima anche a chi aveva già salvato la propria Home; «Personalizza» permette comunque di spostarlo).
- **Scadenza**: «Visibile fino al» (facoltativa). Dal giorno dopo la comunicazione sparisce dalla Bacheca; l'autore la ritrova in «Scadute» per riproporla (cambiando la data) o eliminarla.
- **Categorie**: Generale, Amministrazione, Progetti, Aggiornamenti, Clienti, Team e organizzazione, Marketing, Formazione. Elenco `HM_CATS` in `index.html` (una riga per aggiungerne). Sopra la Bacheca ci sono i filtri per categoria usate.
- Senza la migrazione la Suite funziona come prima (niente foto, categorie né scadenza).

## Aree

**Home**: la prima pagina dopo l'accesso, con scorciatoie a ciò che serve oggi.
- Call di oggi (dal Calendario), email da inviare oggi divise in prima email, follow-up 1 e follow-up 2, saldo del conto aziendale, iscritti alla newsletter, nuove risposte alle email
- Ogni scheda porta alla sezione corrispondente. Nelle call di oggi, un clic sulla call apre il link della chiamata (Meet) e l'ingranaggio accanto apre le impostazioni dell'evento; se la call non ha un link, il clic apre i dettagli
- Online: chi della squadra è nella Suite in questo momento (in alto accanto alla campanella e nella Home), con la sezione in cui si trova; chi ha la scheda in secondo piano risulta «non attivo»
- Messaggi: scambio di messaggi personali tra collaboratori, visibili solo ai due interessati; chi riceve vede una notifica nella campanella. Si può cancellare solo il proprio messaggio
- Bacheca: comunicazioni per tutta la squadra, con titolo facoltativo e possibilità di metterle in evidenza. Ogni comunicazione è una riga compatta (titolo, due righe di anteprima, autore e data); un clic la apre per intero, le azioni stanno nel menu «⋯». Ognuno modifica, mette in evidenza ed elimina solo le proprie; tutti ricevono una notifica quando ne esce una nuova
- Serve la migrazione `20261104150000_messaggi_bacheca.sql` (dopo quella del Calendario)

**Outbound**: campagne email a freddo.
- Dashboard: partenze di oggi, risposte, carico della settimana
- Ricerca lead: ricerche su Google Maps (Apify, tramite il flusso n8n "Ricerca lead da Outbound") con obiettivo di lead e tetto di spesa. Esporta in CSV i lead: scegli la campagna, seleziona i lead (o "Esporta tutti" per quelli filtrati) e premi "Esporta in CSV"
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
- Sincronizzazione con Google, due flussi n8n: «Calendario: Google → Suite» (ogni 5 minuti; crea e aggiorna eventi, annulla quelli cancellati, aggiunge i partecipanti) e «Calendario: Suite → Google» (webhook; crea, aggiorna ed elimina su Google senza inviare email di invito). Le call dell'agenda Azienda senza link ricevono in automatico un link Google Meet (creato da n8n, compare nell'evento entro pochi secondi e nella Home); se si scrive un link a mano, resta quello. Per gli impegni personali, che non vanno su Google, il link si scrive a mano. Gli ospiti esterni indicati nell'evento diventano invitati su Google. Se una persona su Google ha un indirizzo diverso da quello di accesso, si indica in `team_members.email_google`
- Per il link Meet automatico serve anche la migrazione `20261105120000_link_call_meet.sql` (evita una notifica «Evento modificato» quando il link viene aggiunto dal sistema)
- Messa in funzione: creare i quattro utenti in Authentication → Users, eseguire la migrazione `20261104100000_team_calendario_notifiche.sql`, poi per ciascuno `select public.team_aggiungi('email','Nome','#colore');` dal SQL Editor. Per la sincronizzazione servono due segreti in Vault, `calendar_webhook_url` (indirizzo del webhook n8n) e `calendar_webhook_key` (stessa chiave del flusso), e le credenziali Google sui tre nodi HTTP del flusso Suite → Google

**Progetti**: progetti e attività del team, al posto di Notion › Progetti › Project Tracker.
- Attività: un solo riquadro. In alto i filtri (persona: Io, un collega, Tutti; progetto; ricerca) e la scelta «Per stato» / «Per progetto». Sotto, i gruppi richiudibili In corso, Da fare, In attesa, Stand-by (chiuso all'apertura) e «Fatte negli ultimi 7 giorni» (chiuso). Si aggiunge un'attività scrivendola e premendo Invio. La casella a sinistra la segna come fatta (con «Annulla»); lo stato si cambia dal menu sulla riga
- Progetti: un solo elenco a gruppi richiudibili, Attivi (Attivo e Assistenza), Demo, Stand-by, Chiusi, con «Solo i miei» e la ricerca. Lo stato «Stand-by» dei progetti è il valore `pausa` del database. Ogni riga mostra persone, avanzamento (fatte su totali, comprese quelle chiuse in Notion), attività aperte e stato; «Priorità» segna i progetti urgenti
- Pagina del progetto: in alto avanzamento, stato e priorità, cliente, persone, inizio, cartella Drive (con le sottocartelle) e link; sotto le attività con gli stessi gruppi della vista Attività
- Attività: 5 stati (Da fare, In corso, In attesa, Stand-by, Fatto; Stand-by richiede la migrazione `20261111100000_attivita_standby.sql`), persone, scadenza facoltativa, «Urgente», note, file e cartelle di Drive collegati (si incolla il link; con Google collegato e la Google API key nelle Impostazioni si può anche scegliere dal selettore di Drive, che si apre nella cartella del progetto)
- Le cartelle Drive stanno in Drive condiviso › Progetti, una per cliente. Per un progetto nuovo si crea la cartella su Drive e se ne incolla il link nella scheda (se il cliente ha già una cartella, la Suite la propone)
- Notifiche: chi viene aggiunto a un'attività da un collega riceve un avviso nella campanella; un clic apre l'attività. Nella Home c'è la scheda «Le mie attività»
- Messa in funzione: eseguire `20261107100000_progetti_attivita.sql`, poi `20261107100500_progetti_import_notion.sql` per caricare i 18 progetti e le 40 attività aperte di Notion (le attività già chiuse restano come conteggio). Le persone vengono abbinate per nome a `team_members`

**Password**: archivio delle credenziali di Flowline, al posto della pagina Password di Notion.
- Archivio: ricerca, filtro per categoria, aggiunta, modifica ed eliminazione; utente e password si copiano con un clic; la password si può mostrare (si nasconde da sola dopo 20 secondi); generatore di password casuali; importazione di un elenco incollato («servizio ; utente ; password ; sito ; note»)
- Le password sono cifrate nel database (pgcrypto, chiave casuale nel Vault di Supabase `password_archivio_key`, creata dalla migrazione): la tabella non le mostra mai e si aprono solo con la funzione `password_rivela`, riservata alla squadra. **Non cancellare né cambiare quel segreto**, altrimenti le password salvate non si aprono più. La cifratura protegge da fughe e accessi non autorizzati al database, ma chi amministra Supabase può leggere anche la chiave
- Registro accessi: chi ha aggiunto, modificato, eliminato o aperto quale credenziale, e quando (lo vede tutta la squadra)
- Serve la migrazione `20261105100000_password_online.sql`, che attiva anche le regole del canale privato «suite-online» usato da Online

## Dati

Database Supabase "Lead Flowline": `contacts`, `leads`, `lead_searches`, tabelle `newsletter_*`, `richieste_sito`, `conti`, `movimenti`, `team_members`, `eventi`, `evento_partecipanti`, `notifiche`, `messaggi`, `bacheca`, `credenziali`, `password_log`, `progetti`, `attivita`, `linkedin_contatti`, `crm_aziende`, `crm_referenti`, `crm_preventivi`, `crm_incontri`, `crm_documenti`, `crm_elenco`.
Il form del sito scrive in `richieste_sito` solo con la funzione `richiesta_sito_invia`; Newsletter, Ricerca lead, Richieste e Contabilità si leggono dopo il login di un indirizzo presente in `newsletter_editors`; Calendario, Progetti, CRM e Password richiedono un utente in `team_members` (che viene aggiunto anche a `newsletter_editors`).
Le migrazioni e la funzione `nl-track` sono in `supabase/`.

## LinkedIn (10 novembre)

Al posto del database Notion «Ricerca clienti LinkedIn». Sta nell'area **Outbound › LinkedIn**.

- Tabella `linkedin_contatti` (migrazione `20261110190000_linkedin_contatti.sql`): nome, azienda, ruolo, chi se ne occupa, stato (da contattare, contattato, risposto, esito negativo), profilo, e-mail, data invito, data messaggio, testo inviato, risposta, descrizione, note. Tutta la squadra vede e modifica tutto.
- Lista con ricerca, filtri per stato e per referente, ordinamento, cambio di stato direttamente dalla riga (passando a «Contattato» si segna in automatico la data del messaggio), link al profilo oppure ricerca su LinkedIn, copia del messaggio inviato.
- **Aggiungi** per un contatto, **Incolla elenco** per molti insieme (una riga per contatto: `nome ; azienda ; ruolo ; profilo ; e-mail`, anche copiati da un foglio; i doppioni vengono saltati).
- I dati di Notion si caricano con un file SQL a parte (`linkedin_import_notion.sql`). Contiene dati personali, quindi **non sta nel repository**.

## CRM (12 novembre)

Al posto di Notion › Flowline - Dashboard › CRM. Area **CRM** nel menu, con cinque schede: Aziende, Persone, Preventivi, Incontri, Elenchi.

- **Aziende**: una lista divisa per fase (Trattative, Da sviluppare, Clienti, Rete e partner; Progetti conclusi ed Esito negativo chiusi all'apertura), con filtri per fase e settore e ricerca. Gli stati sono quelli di Notion (Da contattare, Contattato, Programmato, In trattativa, Preventivo inviato, Creazione progetto, Supporto post-vendita, Contatto acquisito, Progetto concluso, Negativo) e si cambiano anche dalla riga.
- **Pagina dell'azienda**: stato, settore, provenienza, primo contatto, chi se ne occupa, recapiti; a sinistra la cronologia degli incontri (verbale e prossimi passi) e le note (come è nato il contatto, dati di fatturazione con «Copia»); a destra persone (chiama/scrivi), preventivi, progetti della Suite collegati e documenti.
- **Persone**: rubrica di tutti i referenti con le loro aziende. **Preventivi**: divisi per stato con i totali. **Incontri**: in programma, passati, senza data. **Elenchi**: aziende da valutare (l'elenco «Veneto Orientale» di Notion): «Porta nel CRM» le aggiunge tra le aziende da contattare, «Scarta» le toglie dall'elenco.
- I progetti hanno la colonna `azienda_id`: nella pagina del progetto il cliente apre l'azienda; dalla pagina dell'azienda si collegano e scollegano i progetti.
- Tabelle (migrazione `20261112100000_crm.sql`): `crm_aziende`, `crm_referenti`, `crm_preventivi`, `crm_incontri`, `crm_documenti`, `crm_elenco`. Persone, preventivi, incontri e documenti hanno `aziende bigint[]` (una persona può stare in più aziende). Tutta la squadra vede e modifica tutto.
- I dati di Notion si caricano con un file SQL a parte (`crm_import_notion.sql`, rilanciabile). Contiene nomi, telefoni ed email dei clienti, quindi **non sta nel repository**.
