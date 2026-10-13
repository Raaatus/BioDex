/* Le site : le décor animé, la barre, la galerie, la visionneuse, la documentation. */
(() => {
  'use strict';

  // ── le décor ─────────────────────────────────────────────────────────────
  // Le même moteur que le site Biodex lui-même (fond.js) : on choisit un décor
  // au hasard parmi ceux qui portent la page, et on laisse le visiteur en
  // changer. Son choix est retenu.
  const DECORS = ['aurore', 'etoiles', 'nebuleuse', 'lucioles', 'bulles', 'matrice', 'grille', 'sakura', 'feuilles', 'neige', 'savane', 'lagon', 'aquarelle'];
  const NOMS = { aurore: 'Northern lights', etoiles: 'Starry night', nebuleuse: 'Nebula', lucioles: 'Fireflies', bulles: 'Abyss', matrice: 'Hacker', grille: 'Neon', sakura: 'Sakura', feuilles: 'Forest', neige: 'Winter', savane: 'Savanna', lagon: 'Lagoon', aquarelle: 'Watercolour' };
  const SOMBRES = new Set(['aurore', 'etoiles', 'nebuleuse', 'lucioles', 'bulles', 'matrice', 'grille', 'feuilles', 'savane']);

  function poseDecor(nom) {
    if (typeof Fond === 'undefined') return;
    const reduit = matchMedia('(prefers-reduced-motion: reduce)').matches;
    document.documentElement.classList.toggle('sans-animation', reduit);
    Fond.demarre(nom);
    // Sur un décor clair, le voile et les cartes s'assombrissent un peu plus
    // pour que le texte blanc tienne.
    document.body.classList.toggle('decor-clair', !SOMBRES.has(nom));
    for (const b of document.querySelectorAll('.decors button')) b.classList.toggle('actif', b.dataset.decor === nom);
    try { localStorage.setItem('biodex_site_decor', nom); } catch (_) {}
  }

  function initDecor() {
    let nom = null;
    try { nom = localStorage.getItem('biodex_site_decor'); } catch (_) {}
    if (!DECORS.includes(nom)) nom = 'savane';
    const zone = document.querySelector('.decors');
    if (zone) {
      zone.innerHTML = '<span class="legende">Backdrop of this page — your choice is remembered.</span>'
        + DECORS.map((d) => `<button data-decor="${d}">${NOMS[d]}</button>`).join('');
      zone.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) poseDecor(b.dataset.decor); });
    }
    poseDecor(nom);
  }

  // ── la barre ─────────────────────────────────────────────────────────────
  // Le menu replié des petits écrans, et la pilule qui suit la section lue.
  function initBarre() {
    const barre = document.querySelector('.barre');
    if (!barre) return;
    const bouton = barre.querySelector('.menu');
    bouton?.addEventListener('click', () => {
      const ouverte = barre.classList.toggle('ouverte');
      bouton.setAttribute('aria-expanded', String(ouverte));
    });
    barre.querySelector('.tiroir')?.addEventListener('click', (e) => {
      if (e.target.closest('a')) { barre.classList.remove('ouverte'); bouton?.setAttribute('aria-expanded', 'false'); }
    });

    const liens = [...barre.querySelectorAll('nav a[href^="#"], .tiroir a[href^="#"]')];
    const sections = [...new Set(liens.map((a) => a.getAttribute('href').slice(1)))]
      .map((id) => document.getElementById(id)).filter(Boolean);
    if (!sections.length) return;
    let courante = null;
    const marque = (id) => {
      if (id === courante) return;
      courante = id;
      liens.forEach((a) => a.classList.toggle('actif', a.getAttribute('href') === '#' + id));
    };
    // La section « lue » est celle dont le haut est passé sous la barre ; en
    // haut de page, aucune.
    const suit = () => {
      const ligne = scrollY + 120;
      let id = null;
      for (const s of sections) if (s.offsetTop <= ligne) id = s.id;
      marque(id);
    };
    addEventListener('scroll', suit, { passive: true });
    addEventListener('resize', suit);
    suit();
  }

  // ── ce qui apparaît en défilant, et la lueur sous la souris ─────────────
  function initApparitions() {
    const elements = [...document.querySelectorAll('.apparait')];
    if (!elements.length) return;
    if (!('IntersectionObserver' in window)) { elements.forEach((e) => e.classList.add('visible')); return; }
    const obs = new IntersectionObserver((entrees) => {
      for (const e of entrees) if (e.isIntersecting) { e.target.classList.add('visible'); obs.unobserve(e.target); }
    }, { rootMargin: '0px 0px -8% 0px', threshold: .1 });
    // Un léger décalage entre voisins, pour que la grille se déplie.
    elements.forEach((e, i) => { e.style.transitionDelay = `${(i % 4) * 60}ms`; obs.observe(e); });

    for (const c of document.querySelectorAll('.carte')) {
      c.addEventListener('pointermove', (e) => {
        const r = c.getBoundingClientRect();
        c.style.setProperty('--mx', `${((e.clientX - r.left) / r.width) * 100}%`);
        c.style.setProperty('--my', `${((e.clientY - r.top) / r.height) * 100}%`);
      });
    }
  }

  // ── la galerie : ses filtres, et la visionneuse ─────────────────────────
  function initGalerie() {
    const filtres = document.querySelector('.filtres');
    const figures = [...document.querySelectorAll('.galerie:not(.telephones) figure[data-cat]')];
    filtres?.addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b) return;
      const f = b.dataset.filtre;
      filtres.querySelectorAll('button').forEach((x) => x.classList.toggle('actif', x === b));
      figures.forEach((fig) => fig.classList.toggle('cache', f !== 'tous' && fig.dataset.cat !== f));
    });
  }

  function initVisionneuse() {
    const figures = [...document.querySelectorAll('.galerie figure, .themes figure')];
    if (!figures.length) return;
    const v = document.createElement('div');
    v.className = 'visionneuse';
    v.innerHTML = '<button class="ferme" aria-label="Close">✕</button><button class="prec" aria-label="Previous">‹</button><img alt=""><button class="suiv" aria-label="Next">›</button><div class="legende"></div>';
    document.body.appendChild(v);
    let i = 0;
    const visibles = () => figures.filter((f) => !f.classList.contains('cache'));
    const montre = (k) => {
      const liste = visibles();
      i = (k + liste.length) % liste.length;
      const img = liste[i].querySelector('img');
      v.querySelector('img').src = img.src;
      v.querySelector('.legende').textContent = liste[i].querySelector('figcaption')?.textContent || img.alt || '';
      v.classList.add('ouverte');
    };
    figures.forEach((f) => f.addEventListener('click', () => montre(visibles().indexOf(f))));
    v.querySelector('.ferme').addEventListener('click', () => v.classList.remove('ouverte'));
    v.querySelector('.prec').addEventListener('click', () => montre(i - 1));
    v.querySelector('.suiv').addEventListener('click', () => montre(i + 1));
    v.addEventListener('click', (e) => { if (e.target === v) v.classList.remove('ouverte'); });
    addEventListener('keydown', (e) => {
      if (!v.classList.contains('ouverte')) return;
      if (e.key === 'Escape') v.classList.remove('ouverte');
      if (e.key === 'ArrowLeft') montre(i - 1);
      if (e.key === 'ArrowRight') montre(i + 1);
    });
  }

  // ── le sondage : un serveur public ? ─────────────────────────────────────
  // Le site est statique ; le compteur vit dans un petit Cloudflare Worker
  // (sondage/worker.js) gardé par Turnstile, le captcha gratuit de Cloudflare.
  // Une voix par adresse IP, décidée côté worker. La page se souvient juste
  // qu'on a voté, pour ne pas reproposer le bouton.
  function initSondage() {
    const bloc = document.querySelector('.sondage');
    if (!bloc) return;
    const url = bloc.dataset.url, cle = bloc.dataset.cle;
    const compte = bloc.querySelector('[data-compte]');
    const bouton = bloc.querySelector('.vote');
    const widget = bloc.querySelector('.captcha');
    const etat = bloc.querySelector('.etat');
    if (!url || !cle) { bouton.hidden = true; compte.textContent = ''; return; }

    const montre = (n) => { compte.textContent = n === 0 ? 'be the first' : n === 1 ? '1 vote so far' : `${n} votes so far`; };
    const dejaVote = () => { bouton.classList.add('fait'); bouton.textContent = '👍 Thanks — counted'; bouton.disabled = true; };
    fetch(url).then((r) => r.json()).then((d) => montre(d.total)).catch(() => { compte.textContent = ''; });
    try { if (localStorage.getItem('biodex_sondage_vote')) dejaVote(); } catch (_) {}

    let rendu = false;
    bouton.addEventListener('click', () => {
      if (bouton.disabled) return;
      // Le captcha ne se charge qu'au clic : pas de script tiers pour qui ne vote pas.
      widget.hidden = false;
      if (rendu) return;
      rendu = true;
      const sc = document.createElement('script');
      sc.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
      sc.onload = () => turnstile.render(widget, { sitekey: cle, theme: 'dark', callback: envoie });
      document.head.appendChild(sc);
    });

    async function envoie(token) {
      etat.textContent = '';
      try {
        const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token }) });
        const d = await r.json();
        if (!r.ok) throw new Error(d.erreur || r.status);
        montre(d.total);
        dejaVote();
        try { localStorage.setItem('biodex_sondage_vote', '1'); } catch (_) {}
        etat.textContent = d.deja ? 'This address had already voted.' : '';
      } catch (e) {
        etat.textContent = e.message === 'captcha' ? 'The captcha did not pass — try again.' : 'Could not reach the counter. Try later.';
      } finally { widget.hidden = true; }
    }
  }

  // ── la documentation ─────────────────────────────────────────────────────
  function initDoc() {
    const prose = document.querySelector('.prose');
    if (!prose) return;
    // Un bouton « copier » sur chaque bloc de code.
    for (const pre of prose.querySelectorAll('pre')) {
      const b = document.createElement('button');
      b.className = 'copier'; b.textContent = 'Copy';
      b.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(pre.querySelector('code')?.textContent || pre.textContent); b.textContent = 'Copied'; }
        catch (_) { b.textContent = 'Select and copy'; }
        setTimeout(() => { b.textContent = 'Copy'; }, 1600);
      });
      pre.appendChild(b);
    }
    // Le sommaire suit le défilement.
    const liens = [...document.querySelectorAll('.doc aside a[href^="#"]')];
    const cibles = liens.map((a) => document.getElementById(decodeURIComponent(a.getAttribute('href').slice(1)))).filter(Boolean);
    const obs = new IntersectionObserver((entrees) => {
      for (const e of entrees) {
        if (!e.isIntersecting) continue;
        liens.forEach((a) => a.classList.toggle('actif', a.getAttribute('href') === '#' + e.target.id));
      }
    }, { rootMargin: '-10% 0px -80% 0px' });
    cibles.forEach((c) => obs.observe(c));
    // Le filtre du sommaire.
    const champ = document.querySelector('.doc aside input');
    champ?.addEventListener('input', () => {
      const q = champ.value.trim().toLowerCase();
      liens.forEach((a) => { a.style.display = !q || a.textContent.toLowerCase().includes(q) ? '' : 'none'; });
    });
  }

  document.addEventListener('DOMContentLoaded', () => { initDecor(); initBarre(); initApparitions(); initGalerie(); initVisionneuse(); initSondage(); initDoc(); });
})();
