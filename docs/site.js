/* Le site : le décor animé, la visionneuse des captures, la documentation. */
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
    if (!DECORS.includes(nom)) nom = ['aurore', 'etoiles', 'nebuleuse', 'lucioles'][Math.floor(Math.random() * 4)];
    const zone = document.querySelector('.decors');
    if (zone) {
      zone.innerHTML = DECORS.map((d) => `<button data-decor="${d}">${NOMS[d]}</button>`).join('');
      zone.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) poseDecor(b.dataset.decor); });
    }
    poseDecor(nom);
  }

  // ── la visionneuse ───────────────────────────────────────────────────────
  function initVisionneuse() {
    const figures = [...document.querySelectorAll('.galerie figure, .themes figure')];
    if (!figures.length) return;
    const v = document.createElement('div');
    v.className = 'visionneuse';
    v.innerHTML = '<button class="ferme" aria-label="Close">✕</button><button class="prec" aria-label="Previous">‹</button><img alt=""><button class="suiv" aria-label="Next">›</button><div class="legende"></div>';
    document.body.appendChild(v);
    let i = 0;
    const montre = (k) => {
      i = (k + figures.length) % figures.length;
      const img = figures[i].querySelector('img');
      v.querySelector('img').src = img.src;
      v.querySelector('.legende').textContent = figures[i].querySelector('figcaption')?.textContent || img.alt || '';
      v.classList.add('ouverte');
    };
    figures.forEach((f, k) => f.addEventListener('click', () => montre(k)));
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

  document.addEventListener('DOMContentLoaded', () => { initDecor(); initVisionneuse(); initDoc(); });
})();
