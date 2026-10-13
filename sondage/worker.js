/* Le compteur du sondage « un serveur public ? » — un Cloudflare Worker.
 *
 * Le site est statique ; ce petit programme est le seul serveur derrière lui,
 * et il ne fait que trois choses :
 *   GET  /   → { total }           le nombre de voix
 *   POST /   → { total, deja? }    une voix de plus, si le captcha passe et
 *                                  que cette adresse IP n'a pas déjà voté
 * Le captcha est Turnstile (Cloudflare, gratuit). L'adresse IP n'est jamais
 * gardée en clair : on stocke une empreinte salée, un an, juste pour refuser
 * la seconde voix.
 *
 * Variables : VOTES (un espace KV), TURNSTILE_SECRET et SEL (des secrets),
 * ORIGINE (l'adresse du site, pour le CORS). Voir README.md.
 */
export default {
  async fetch(req, env) {
    const cors = {
      'Access-Control-Allow-Origin': env.ORIGINE || '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'content-type',
      'Cache-Control': 'no-store',
    };
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (req.method === 'GET') return json({ total: await total(env) }, cors);
    if (req.method !== 'POST') return json({ erreur: 'methode' }, cors, 405);

    const ip = req.headers.get('CF-Connecting-IP') || '';
    const { token } = await req.json().catch(() => ({}));
    const verif = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ secret: env.TURNSTILE_SECRET, response: token || '', remoteip: ip }),
    }).then((r) => r.json()).catch(() => ({ success: false }));
    if (!verif.success) return json({ erreur: 'captcha' }, cors, 403);

    const cle = 'ip:' + await empreinte(ip + (env.SEL || ''));
    if (await env.VOTES.get(cle)) return json({ total: await total(env), deja: true }, cors);
    await env.VOTES.put(cle, '1', { expirationTtl: 365 * 86400 });
    const n = (await total(env)) + 1;
    await env.VOTES.put('total', String(n));
    return json({ total: n }, cors);
  },
};

const total = async (env) => Number(await env.VOTES.get('total')) || 0;

const json = (corps, entetes, statut = 200) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { ...entetes, 'content-type': 'application/json' } });

async function empreinte(texte) {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texte));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
