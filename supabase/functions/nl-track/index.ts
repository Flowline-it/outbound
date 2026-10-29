// nl-track — statistiche anonime della newsletter Flowline (progetto Supabase "Lead Flowline").
//   GET /nl-track/o?c=<campagna>&n=<codice>&t=<invio>          → immagine 1×1, conta un'apertura
//   GET /nl-track/c?c=<campagna>&n=<codice>&t=<invio>&u=<link> → conta un clic e porta al link
// <codice> è casuale per ogni email e non è salvato con il destinatario: si contano persone distinte, non chi sono.
// Il redirect accetta solo link presenti nel testo di quella newsletter (niente redirect verso siti a caso).
// Deploy con verify_jwt = false: viene chiamata dai programmi di posta, senza login.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

const GIF = Uint8Array.from(atob('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'), (ch) => ch.charCodeAt(0));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NONCE = /^[a-z0-9]{8,40}$/;
// filtri antispam aziendali, anteprime e script: aprono e cliccano da soli, li teniamo fuori dai numeri
const BOT_UA = /bot|crawl|spider|preview|scan|proofpoint|mimecast|barracuda|bitdefender|forcepoint|python|curl|wget|go-http|headless|monitor|zgrab/i;
const FALLBACK = 'https://flowline.it/';
const LINK = /\[[^\]]+\]\((https?:\/\/[^)\s"']+)\)/g;

const noStore = { 'Cache-Control': 'no-store, no-cache, must-revalidate, private', Pragma: 'no-cache', Expires: '0' };

function isBot(req: Request, sentAt: number) {
  const ua = req.headers.get('user-agent') || '';
  const age = sentAt > 0 ? Date.now() / 1000 - sentAt : Infinity;
  return req.method === 'HEAD' || BOT_UA.test(ua) || (age >= 0 && age < 20); // nessuna persona apre in meno di 20 secondi
}

async function record(row: Record<string, unknown>) {
  const { error } = await sb.from('newsletter_events').insert(row);
  if (error) console.error('nl-track insert', error.message);
}

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const kind = u.pathname.split('/').filter(Boolean).pop();
  const c = u.searchParams.get('c') || '';
  const n = (u.searchParams.get('n') || '').toLowerCase();
  const t = Number(u.searchParams.get('t') || 0);
  const valid = UUID.test(c) && NONCE.test(n);

  if (kind === 'c') {
    const target = u.searchParams.get('u') || '';
    let dest = FALLBACK;
    if (valid && /^https?:\/\//i.test(target) && target.length <= 2000) {
      const { data } = await sb.from('newsletter_campaigns').select('body').eq('id', c).maybeSingle();
      const links = data ? [...String(data.body).matchAll(LINK)].map((m) => m[1]) : [];
      if (links.includes(target)) {
        dest = target;
        await record({ campaign_id: c, type: 'click', nonce: n, url: target, bot: isBot(req, t) });
      }
    }
    return new Response(null, { status: 302, headers: { Location: dest, 'Referrer-Policy': 'no-referrer', ...noStore } });
  }

  if (kind === 'o' && valid) await record({ campaign_id: c, type: 'open', nonce: n, bot: isBot(req, t) });
  return new Response(req.method === 'HEAD' ? null : GIF, { headers: { 'Content-Type': 'image/gif', ...noStore } });
});
