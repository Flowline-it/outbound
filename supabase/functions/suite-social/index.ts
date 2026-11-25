// suite-social — post social e articoli del Journal per la Flowline Suite (Marketing › Social e Notizie).
// Va pubblicata nel progetto Supabase FLOWLINE JOURNAL (dove vive la tabella social_posts), con verify_jwt = false.
// La Suite ha il suo database (altro progetto), quindi il Journal non può verificare il suo accesso da solo:
// la funzione chiede al database della Suite se il token è valido e se chi chiama è una persona attiva della
// squadra (team_members). Solo allora usa la chiave di servizio.
//  - Lettura (corpo { da?, a? }): social_posts, social_temi e journal_articles (senza il testo).
//  - Scelta della piattaforma (corpo { azione: 'piattaforme', post_id, piattaforme }): piattaforme = ['linkedin'],
//    ['instagram'], ['linkedin','instagram'] oppure null (regola predefinita: 13:00 su entrambi, 18:00 solo LinkedIn).
//    Si può cambiare finché il post non è uscito e l'orario non è passato. L'attività "programma" (ogni ora alle :40)
//    la applica: programma le piattaforme aggiunte e salta quelle tolte ancora in approvazione.
// URL e chiave publishable della Suite sono pubblici (stanno già in index.html).
const SUITE_URL = 'https://adaaubcarnczlmenfwam.supabase.co';
const SUITE_KEY = 'sb_publishable_0a_ioaj4iiT3MlzUKR2XyQ_-PYHrQPP';
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const romeToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome' }).format(new Date());
const romeNow = () => {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date());
  const g = (t: string) => p.find((x) => x.type === t)?.value || '';
  return `${g('year')}-${g('month')}-${g('day')} ${g('hour')}:${g('minute')}`;
};
const shift = (day: string, n: number) => {
  const d = new Date(day + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

async function teamMember(token: string): Promise<string | null> {
  const h = { apikey: SUITE_KEY, Authorization: 'Bearer ' + token };
  const u = await fetch(SUITE_URL + '/auth/v1/user', { headers: h });
  if (!u.ok) return null;
  const id = (await u.json())?.id;
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) return null;
  const m = await fetch(`${SUITE_URL}/rest/v1/team_members?select=id&id=eq.${id}&attivo=eq.true`, { headers: h });
  if (!m.ok) return null;
  const rows = await m.json();
  return Array.isArray(rows) && rows.length === 1 ? id : null;
}

const SH = { apikey: SB_SERVICE, Authorization: 'Bearer ' + SB_SERVICE };
const sbGet = async (path: string) => {
  const r = await fetch(SB_URL + '/rest/v1/' + path, { headers: SH });
  if (!r.ok) throw new Error('database ' + r.status);
  return r.json();
};

const ART_COLS = 'id,title,slug,status,scheduled_at,published_at,source_url';
const POST_COLS = 'id,giorno,orario,tipo,formato,stato,linkedin_stato,instagram_stato,titolo_grafica,testo_linkedin,testo_instagram,link_articolo,immagine_url,slide_urls,linkedin_approval_id,instagram_approval_id,note,email_approvazione_inviata,article_id,tema_id,piattaforme,piattaforme_modificate_il,created_at,updated_at';
const NOMI: Record<string, string> = { linkedin: 'LinkedIn', instagram: 'Instagram' };

async function cambiaPiattaforme(body: any) {
  const postId = String(body.post_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(postId)) return json({ ok: false, errore: 'Post non valido.' }, 400);
  let scelta: string[] | null = null;
  if (body.piattaforme !== null && body.piattaforme !== undefined) {
    if (!Array.isArray(body.piattaforme)) return json({ ok: false, errore: 'Scelta non valida.' }, 400);
    scelta = [...new Set(body.piattaforme.map((x: unknown) => String(x)))].filter((x) => x === 'linkedin' || x === 'instagram').sort();
    if (!scelta.length) return json({ ok: false, errore: 'Scegli almeno una piattaforma.' }, 400);
  }
  const rows = await sbGet(`social_posts?select=${POST_COLS}&id=eq.${postId}`);
  const r = rows && rows[0];
  if (!r) return json({ ok: false, errore: 'Post non trovato.' }, 404);
  if (r.stato === 'pubblicato') return json({ ok: false, errore: 'Il post è già uscito: non si può più cambiare.' }, 409);
  if (r.stato === 'saltato') return json({ ok: false, errore: 'Il post è stato saltato: non esce più.' }, 409);
  if (`${r.giorno} ${r.orario}` <= romeNow()) return json({ ok: false, errore: "L'orario di uscita è già passato." }, 409);

  const avvisi: string[] = [];
  const dopo = scelta || (r.orario === '18:00' ? ['linkedin'] : ['instagram', 'linkedin']);
  for (const p of ['linkedin', 'instagram']) {
    if (!dopo.includes(p) && r[p + '_stato'] === 'programmato') avvisi.push(`${NOMI[p]} è già approvato: per toglierlo cancella il post in Creads.`);
  }
  if (['post_in_approvazione', 'programmato'].includes(r.stato)) avvisi.push('Il post è già in programmazione: il flusso applica la modifica al prossimo giro (ogni ora alle :40). Se aggiungi una piattaforma, arriva una nuova email di approvazione.');

  const up = await fetch(`${SB_URL}/rest/v1/social_posts?id=eq.${postId}&select=${POST_COLS}`, {
    method: 'PATCH',
    headers: { ...SH, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify({ piattaforme: scelta, piattaforme_modificate_il: new Date().toISOString() }),
  });
  if (!up.ok) throw new Error('database ' + up.status);
  const nuovo = (await up.json())[0];
  return json({ ok: true, post: nuovo, avvisi });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, errore: 'Usa POST.' }, 405);
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return json({ ok: false, errore: 'Accesso mancante.' }, 401);
  try {
    if (!(await teamMember(token))) return json({ ok: false, errore: 'Accesso non abilitato.' }, 403);
    let body: { da?: string; a?: string; azione?: string } = {};
    try { body = await req.json(); } catch { /* corpo vuoto: periodo predefinito */ }
    if (body.azione === 'piattaforme') return await cambiaPiattaforme(body);
    const oggi = romeToday();
    const da = body.da && DAY.test(body.da) ? body.da : shift(oggi, -35);
    let a = body.a && DAY.test(body.a) ? body.a : shift(oggi, 14);
    if (a < da) a = da;
    if (a > shift(da, 120)) a = shift(da, 120);   // al massimo quattro mesi per volta
    // articoli del Journal: gli ultimi 120 giorni, più quelli non ancora pubblicati o programmati nel futuro
    const artDa = shift(oggi, -120);
    const [posts, temi, articoli] = await Promise.all([
      sbGet(`social_posts?select=${POST_COLS}&giorno=gte.${da}&giorno=lte.${a}&giorno=lt.2030-01-01&order=giorno.asc,orario.asc&limit=400`),
      sbGet('social_temi?select=id,ordine,servizio,tema,attivo,usato_il&attivo=eq.true&order=ordine.asc&limit=200'),
      sbGet(`journal_articles?select=${ART_COLS}&or=(published_at.gte.${artDa},scheduled_at.gte.${artDa},status.neq.published)&order=published_at.desc.nullsfirst&limit=400`).catch(() => null),
    ]);
    return json({ ok: true, oggi, da, a, posts, temi, articoli });
  } catch (e) {
    return json({ ok: false, errore: String((e as Error).message || e) }, 500);
  }
});
