// suite-social — lettura dei post social per la Flowline Suite (Marketing › Social).
// Va pubblicata nel progetto Supabase FLOWLINE JOURNAL (dove vive la tabella social_posts), con verify_jwt = false.
// La Suite ha il suo database (altro progetto), quindi il Journal non può verificare il suo accesso da solo:
// la funzione chiede al database della Suite se il token è valido e se chi chiama è una persona attiva della
// squadra (team_members). Solo allora legge social_posts e social_temi con la chiave di servizio.
// Sola lettura: non scrive nulla. URL e chiave publishable della Suite sono pubblici (stanno già in index.html).
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
const shift = (day: string, n: number) => {
  const d = new Date(day + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

async function isTeamMember(token: string): Promise<boolean> {
  const h = { apikey: SUITE_KEY, Authorization: 'Bearer ' + token };
  const u = await fetch(SUITE_URL + '/auth/v1/user', { headers: h });
  if (!u.ok) return false;
  const id = (await u.json())?.id;
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) return false;
  const m = await fetch(`${SUITE_URL}/rest/v1/team_members?select=id&id=eq.${id}&attivo=eq.true`, { headers: h });
  if (!m.ok) return false;
  const rows = await m.json();
  return Array.isArray(rows) && rows.length === 1;
}

const sbGet = async (path: string) => {
  const r = await fetch(SB_URL + '/rest/v1/' + path, { headers: { apikey: SB_SERVICE, Authorization: 'Bearer ' + SB_SERVICE } });
  if (!r.ok) throw new Error('database ' + r.status);
  return r.json();
};

const POST_COLS = 'id,giorno,orario,tipo,formato,stato,linkedin_stato,instagram_stato,titolo_grafica,testo_linkedin,testo_instagram,link_articolo,immagine_url,slide_urls,linkedin_approval_id,instagram_approval_id,note,email_approvazione_inviata,article_id,tema_id,created_at,updated_at';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, errore: 'Usa POST.' }, 405);
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return json({ ok: false, errore: 'Accesso mancante.' }, 401);
  try {
    if (!(await isTeamMember(token))) return json({ ok: false, errore: 'Accesso non abilitato.' }, 403);
    let body: { da?: string; a?: string } = {};
    try { body = await req.json(); } catch { /* corpo vuoto: periodo predefinito */ }
    const oggi = romeToday();
    const da = body.da && DAY.test(body.da) ? body.da : shift(oggi, -35);
    let a = body.a && DAY.test(body.a) ? body.a : shift(oggi, 14);
    if (a < da) a = da;
    if (a > shift(da, 120)) a = shift(da, 120);   // al massimo quattro mesi per volta
    const [posts, temi] = await Promise.all([
      sbGet(`social_posts?select=${POST_COLS}&giorno=gte.${da}&giorno=lte.${a}&order=giorno.asc,orario.asc&limit=400`),
      sbGet('social_temi?select=id,ordine,servizio,tema,attivo,usato_il&attivo=eq.true&order=ordine.asc&limit=200'),
    ]);
    return json({ ok: true, oggi, da, a, posts, temi });
  } catch (e) {
    return json({ ok: false, errore: String((e as Error).message || e) }, 500);
  }
});
