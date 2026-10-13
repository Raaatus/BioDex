/*
 * Les fonds animés des thèmes.
 *
 * Un canevas fixe, plein écran, posé **derrière** la page : il ne passe devant
 * rien, il remplit ce que la page laisse transparent. Chaque thème « poussé »
 * y dessine son décor — pluie de signes, étoiles, feuilles, pétales, bulles,
 * grille, neige. Le cycle de vie est commun, seul le dessin change.
 *
 * Sobre sur la batterie : vingt-quatre images par seconde et non soixante,
 * rien quand l'onglet est caché, et rien du tout si les animations sont
 * coupées dans les réglages — il reste alors une seule image figée.
 */
const Fond = (() => {
  'use strict';

  const CADENCE = 1000 / 24;
  const hasard = (a, b) => a + Math.random() * (b - a);

  let toile = null;
  let ctx = null;
  let effet = null;      // l'effet en cours : { init, image }
  let L = 0;
  let H = 0;
  let derniere = 0;
  let boucle = 0;
  let actif = false;
  let temps = 0;         // en images, pour les oscillations

  /* ── les effets ───────────────────────────────────────────────────────
   *
   * Chacun expose `init()` — appelé à la création et à chaque redimension —
   * et `image(t)`, qui dessine une image complète (fond compris : le canevas
   * est opaque, c'est lui le fond). */
  const EFFETS = {};

  /* La pluie de signes du thème hacker. */
  EFFETS.matrice = (() => {
    const SIGNES = 'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモ'
                 + 'ヤユヨラリルレロワン0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$+-*/<>=#%&';
    const TAILLE = 15;
    let colonnes = [];
    return {
      init() {
        ctx.font = `${TAILLE}px ui-monospace, Menlo, Consolas, monospace`;
        colonnes = Array.from({ length: Math.ceil(L / TAILLE) },
                              () => ({ y: Math.random() * H / TAILLE, v: hasard(.35, 1.25) }));
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, L, H);
      },
      image() {
        // La traîne : un voile presque transparent, et l'ancien s'estompe.
        ctx.fillStyle = 'rgba(0, 0, 0, .09)';
        ctx.fillRect(0, 0, L, H);
        ctx.font = `${TAILLE}px ui-monospace, Menlo, Consolas, monospace`;
        for (let i = 0; i < colonnes.length; i++) {
          const c = colonnes[i];
          const x = i * TAILLE;
          const y = Math.floor(c.y) * TAILLE;
          ctx.fillStyle = '#c8ffd0';
          ctx.fillText(SIGNES[Math.floor(Math.random() * SIGNES.length)], x, y);
          ctx.fillStyle = '#19c94a';
          ctx.fillText(SIGNES[Math.floor(Math.random() * SIGNES.length)], x, y - TAILLE);
          c.y += c.v;
          if (y > H && Math.random() > .975) c.y = 0;
        }
      },
    };
  })();

  /* Nuit étoilée : des étoiles qui scintillent, et de temps en temps une
   * filante. */
  EFFETS.etoiles = (() => {
    let etoiles = [];
    let filante = null;
    return {
      init() {
        etoiles = Array.from({ length: Math.round(L * H / 4500) }, () => ({
          x: Math.random() * L, y: Math.random() * H,
          r: hasard(.4, 1.7), phase: Math.random() * Math.PI * 2, v: hasard(.02, .08),
          teinte: Math.random() < .15 ? '255, 220, 170' : Math.random() < .2 ? '190, 210, 255' : '255, 255, 255',
        }));
      },
      image(t) {
        const g = ctx.createLinearGradient(0, 0, 0, H);
        g.addColorStop(0, '#05081a'); g.addColorStop(1, '#0d1430');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, L, H);
        for (const e of etoiles) {
          const a = .45 + .55 * Math.sin(e.phase + t * e.v) ** 2;
          ctx.fillStyle = `rgba(${e.teinte}, ${a.toFixed(3)})`;
          ctx.beginPath(); ctx.arc(e.x, e.y, e.r, 0, Math.PI * 2); ctx.fill();
        }
        // Une filante toutes les cinq à dix secondes, pas plus : c'est leur
        // rareté qui fait qu'on les remarque.
        if (!filante && Math.random() < 1 / 180) {
          filante = { x: hasard(0, L * .8), y: hasard(0, H * .4), vx: hasard(9, 14), vy: hasard(4, 7), vie: 0 };
        }
        if (filante) {
          const f = filante;
          const long = 14;
          const grad = ctx.createLinearGradient(f.x, f.y, f.x - f.vx * long / 4, f.y - f.vy * long / 4);
          grad.addColorStop(0, 'rgba(255,255,255,.95)'); grad.addColorStop(1, 'rgba(255,255,255,0)');
          ctx.strokeStyle = grad; ctx.lineWidth = 1.6; ctx.lineCap = 'round';
          ctx.beginPath(); ctx.moveTo(f.x, f.y); ctx.lineTo(f.x - f.vx * long / 4, f.y - f.vy * long / 4); ctx.stroke();
          f.x += f.vx; f.y += f.vy; f.vie += 1;
          if (f.vie > 28 || f.x > L || f.y > H) filante = null;
        }
      },
    };
  })();

  /* ── les formes ───────────────────────────────────────────────────────
   *
   * Dessinées dans un repère unitaire (de -1 à 1), puis posées à l'échelle :
   * une feuille d'érable à 8 px et à 30 px est la même feuille. */

  /* Une feuille d'érable : cinq lobes pointus. Le tracé est un polygone, les
   * nervures partent du pétiole vers chaque lobe. */
  const ERABLE = [[0, -1], [.18, -.55], [.52, -.72], [.42, -.3], [.95, -.38], [.6, .02], [.78, .42],
                  [.3, .3], [.14, .9], [0, .6], [-.14, .9], [-.3, .3], [-.78, .42], [-.6, .02],
                  [-.95, -.38], [-.42, -.3], [-.52, -.72], [-.18, -.55]];
  function erable() {
    ctx.beginPath();
    ERABLE.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath(); ctx.fill();
    ctx.beginPath();
    for (const [x, y] of [[0, -1], [.95, -.38], [.78, .42], [-.78, .42], [-.95, -.38]]) { ctx.moveTo(0, .6); ctx.lineTo(x * .9, y * .9); }
    ctx.moveTo(0, .6); ctx.lineTo(0, 1.25);   // le pétiole
    ctx.stroke();
  }

  /* Une feuille de chêne : des lobes arrondis de part et d'autre de la
   * nervure, plus larges vers la pointe. */
  function chene() {
    ctx.beginPath();
    for (let i = 0; i <= 60; i++) {
      const a = i / 60 * Math.PI * 2;
      const lobes = 1 + .22 * Math.cos(a * 5 + Math.PI);
      const x = Math.sin(a) * .55 * lobes * (1 - .25 * Math.cos(a));
      const y = -Math.cos(a) * lobes;
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    }
    ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.moveTo(0, 1.3); ctx.lineTo(0, -.9);
    for (let k = -.6; k < .8; k += .35) { ctx.moveTo(0, k); ctx.lineTo(.4, k - .25); ctx.moveTo(0, k); ctx.lineTo(-.4, k - .25); }
    ctx.stroke();
  }

  /* Une feuille simple — hêtre, charme — en pointe, nervure et veines. */
  function hetre() {
    ctx.beginPath();
    ctx.moveTo(0, -1);
    ctx.bezierCurveTo(.7, -.6, .7, .5, 0, 1);
    ctx.bezierCurveTo(-.7, .5, -.7, -.6, 0, -1);
    ctx.fill();
    ctx.beginPath(); ctx.moveTo(0, 1.3); ctx.lineTo(0, -.95);
    for (let k = -.55; k < .7; k += .3) { ctx.moveTo(0, k); ctx.lineTo(.42, k - .3); ctx.moveTo(0, k); ctx.lineTo(-.42, k - .3); }
    ctx.stroke();
  }

  /* Un pétale de cerisier : large, et l'encoche au bout, celle qui le
   * distingue d'un pétale de pommier. */
  function petale() {
    ctx.beginPath();
    ctx.moveTo(0, 1);
    ctx.bezierCurveTo(.95, .75, .95, -.45, .38, -.9);
    ctx.quadraticCurveTo(.18, -1.02, 0, -.68);
    ctx.quadraticCurveTo(-.18, -1.02, -.38, -.9);
    ctx.bezierCurveTo(-.95, -.45, -.95, .75, 0, 1);
    ctx.fill();
  }

  /* Une fleur entière : cinq pétales autour d'un cœur, pour quelques-unes
   * qui tombent avec leur fleur. */
  function fleur() {
    for (let i = 0; i < 5; i++) {
      ctx.save(); ctx.rotate(i / 5 * Math.PI * 2); ctx.translate(0, -.95); ctx.scale(.55, .9); petale(); ctx.restore();
    }
    ctx.fillStyle = '#f4d35e';
    for (let i = 0; i < 6; i++) { const a = i / 6 * Math.PI * 2; ctx.beginPath(); ctx.arc(Math.cos(a) * .22, Math.sin(a) * .22, .09, 0, Math.PI * 2); ctx.fill(); }
  }

  /* Pose une forme unitaire à un endroit, à une échelle, tournée. */
  function pose(x, y, echelle, angle, couleur, trait, dessine) {
    ctx.save();
    ctx.translate(x, y); ctx.rotate(angle); ctx.scale(echelle, echelle);
    ctx.fillStyle = couleur;
    ctx.strokeStyle = trait; ctx.lineWidth = 1.2 / echelle; ctx.lineCap = 'round';
    dessine();
    ctx.restore();
  }

  /* Un acacia parasol : le tronc, quelques branches qui s'écartent, et la
   * cime plate aux bords dentelés qu'on reconnaît de loin. */
  function acacia(x, y, h, l) {
    ctx.fillStyle = '#120806'; ctx.strokeStyle = '#120806'; ctx.lineCap = 'round';
    ctx.beginPath(); ctx.moveTo(x - 3.5, y); ctx.lineTo(x + 3.5, y); ctx.lineTo(x + 1.5, y - h * .42); ctx.lineTo(x - 1.5, y - h * .42); ctx.fill();
    const haut = y - h * .42;
    const cime = haut - h * .3;
    for (const [dx, dy] of [[-l * .36, -h * .22], [l * .34, -h * .25], [-l * .12, -h * .3], [l * .14, -h * .29], [-l * .24, -h * .27]]) {
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(x, haut); ctx.quadraticCurveTo(x + dx * .35, haut + dy * .4, x + dx, haut + dy); ctx.stroke();
      ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.moveTo(x + dx * .6, haut + dy * .6); ctx.lineTo(x + dx * .9, haut + dy * .95 - 6); ctx.stroke();
    }
    // La cime : un dessus presque plat, un dessous festonné, un peu plus
    // épais au centre qu'aux extrémités.
    ctx.beginPath();
    ctx.moveTo(x - l / 2, cime + 2);
    for (let i = 0; i <= 10; i++) {
      const px = x - l / 2 + l * i / 10;
      ctx.lineTo(px, cime - (i === 0 || i === 10 ? 0 : 3 + 3 * Math.abs(Math.sin(i * 2.1))));
    }
    for (let i = 10; i >= 0; i--) {
      const px = x - l / 2 + l * i / 10;
      const prof = 6 + h * .13 * (1 - Math.abs(i - 5) / 5.5);
      ctx.quadraticCurveTo(px + l / 20, cime + prof + 5, px - l / 20, cime + prof);
    }
    ctx.closePath(); ctx.fill();
    // Une seconde couronne, plus petite, au-dessus : la cime n'est jamais
    // d'un seul tenant.
    ctx.beginPath();
    const l2 = l * .45, c2 = cime - h * .1, x2 = x + l * .08;
    ctx.moveTo(x2 - l2 / 2, c2 + 4);
    for (let i = 0; i <= 6; i++) ctx.lineTo(x2 - l2 / 2 + l2 * i / 6, c2 - (i === 0 || i === 6 ? 0 : 3));
    for (let i = 6; i >= 0; i--) { const px = x2 - l2 / 2 + l2 * i / 6; ctx.quadraticCurveTo(px + l2 / 12, c2 + 10, px - l2 / 12, c2 + 6); }
    ctx.closePath(); ctx.fill();
  }

  /* Des choses qui tombent en se balançant : feuilles, pétales, flocons. */
  function chute({ fond, combien, taille, couleurs, vitesse, balancement, forme, vent = 0 }) {
    let parts = [];
    const neuve = (haut) => ({
      x: Math.random() * L, y: haut ? -20 : Math.random() * H,
      l: hasard(taille[0], taille[1]), v: hasard(vitesse[0], vitesse[1]),
      phase: Math.random() * Math.PI * 2, bal: hasard(balancement[0], balancement[1]),
      rot: Math.random() * Math.PI * 2, vrot: hasard(-.05, .05),
      c: couleurs[Math.floor(Math.random() * couleurs.length)],
    });
    return {
      init() { parts = Array.from({ length: Math.round(combien * L * H / (390 * 844)) }, () => neuve(false)); },
      image(t) {
        fond();
        for (const p of parts) {
          const x = p.x + Math.sin(t * .04 + p.phase) * p.bal + t * vent;
          forme(x % (L + 40) - 20, p.y, p, t);
          p.y += p.v; p.rot += p.vrot;
          if (p.y > H + 20) Object.assign(p, neuve(true));
        }
      },
    };
  }

  /* Forêt : des feuilles d'automne qui descendent en tournant. */
  EFFETS.feuilles = chute({
    fond() {
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#101a14'); g.addColorStop(1, '#16241b');
      ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
    },
    combien: 30, taille: [7, 13], vitesse: [.5, 1.3], balancement: [10, 30],
    couleurs: ['#b8702c', '#c9922f', '#8c4a1f', '#6e7f2a', '#a35a24', '#d4a94a', '#c1392b'],
    // Trois essences, tirées à la création de chaque feuille.
    forme(x, y, p) {
      p.essence ??= [erable, chene, hetre][Math.floor(Math.random() * 3)];
      pose(x, y, p.l, p.rot, p.c, 'rgba(40, 20, 5, .45)', p.essence);
    },
  });

  /* Sakura : des pétales roses qui dérivent dans un vent léger. */
  EFFETS.sakura = chute({
    fond() {
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#fff8fb'); g.addColorStop(1, '#ffeef4');
      ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
    },
    combien: 40, taille: [5, 9], vitesse: [.4, 1.1], balancement: [14, 36], vent: .25,
    couleurs: ['#ffc2d4', '#ffb0c8', '#ffd3df', '#f9a0bd', '#ffe0ea'],
    // Surtout des pétales, et une fleur entière sur huit.
    forme(x, y, p) {
      p.entiere ??= Math.random() < .12;
      if (p.entiere) pose(x, y, p.l * 1.1, p.rot, p.c, 'rgba(0,0,0,0)', fleur);
      else {
        // Du plus soutenu à la base vers le bout plus clair.
        ctx.save(); ctx.translate(x, y); ctx.rotate(p.rot); ctx.scale(p.l, p.l);
        const g = ctx.createLinearGradient(0, 1, 0, -1); g.addColorStop(0, '#f48fb1'); g.addColorStop(1, p.c);
        ctx.fillStyle = g; petale(); ctx.restore();
      }
    },
  });

  /* Hiver : la neige, lente, un peu de vent. */
  EFFETS.neige = chute({
    fond() {
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#e9f0f8'); g.addColorStop(1, '#f6f9fc');
      ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
    },
    combien: 90, taille: [1.2, 3.6], vitesse: [.35, 1.1], balancement: [6, 18], vent: .12,
    couleurs: ['rgba(255,255,255,.95)', 'rgba(220,232,245,.9)', 'rgba(200,215,235,.85)'],
    forme(x, y, p) { ctx.fillStyle = p.c; ctx.beginPath(); ctx.arc(x, y, p.l, 0, Math.PI * 2); ctx.fill(); },
  });

  /* Abysses : des bulles qui montent, un peu de lumière qui tombe d'en haut. */
  EFFETS.bulles = (() => {
    let bulles = [];
    const neuve = (bas) => ({
      x: Math.random() * L, y: bas ? H + 10 : Math.random() * H,
      r: hasard(1.5, 6), v: hasard(.4, 1.4), phase: Math.random() * Math.PI * 2, bal: hasard(4, 14),
    });
    return {
      init() { bulles = Array.from({ length: Math.round(45 * L * H / (390 * 844)) }, () => neuve(false)); },
      image(t) {
        const g = ctx.createRadialGradient(L / 2, -H * .1, 0, L / 2, -H * .1, H * 1.1);
        g.addColorStop(0, '#0d4466'); g.addColorStop(.55, '#06223a'); g.addColorStop(1, '#030d1a');
        ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
        // Les rais de lumière : des bandes pâles qui respirent.
        for (let i = 0; i < 4; i++) {
          const cx = L * (.15 + i * .25) + Math.sin(t * .01 + i) * 30;
          const r = ctx.createLinearGradient(cx, 0, cx + 60, H * .8);
          r.addColorStop(0, `rgba(80, 200, 220, ${(.05 + .03 * Math.sin(t * .02 + i)).toFixed(3)})`);
          r.addColorStop(1, 'rgba(80, 200, 220, 0)');
          ctx.fillStyle = r;
          ctx.beginPath(); ctx.moveTo(cx - 25, 0); ctx.lineTo(cx + 25, 0); ctx.lineTo(cx + 140, H); ctx.lineTo(cx - 60, H); ctx.fill();
        }
        for (const b of bulles) {
          const x = b.x + Math.sin(t * .05 + b.phase) * b.bal;
          ctx.strokeStyle = 'rgba(160, 230, 240, .55)'; ctx.lineWidth = 1;
          ctx.beginPath(); ctx.arc(x, b.y, b.r, 0, Math.PI * 2); ctx.stroke();
          ctx.fillStyle = 'rgba(200, 245, 255, .35)';
          ctx.beginPath(); ctx.arc(x - b.r * .35, b.y - b.r * .35, b.r * .3, 0, Math.PI * 2); ctx.fill();
          b.y -= b.v;
          if (b.y < -10) Object.assign(b, neuve(true));
        }
      },
    };
  })();

  /* Néon : la grille synthwave qui défile vers soi, et le soleil derrière. */
  EFFETS.grille = {
    init() {},
    image(t) {
      const horizon = H * .42;
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#0d0620'); g.addColorStop(.42, '#2a0f45'); g.addColorStop(1, '#120a1f');
      ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
      // Le soleil rayé, à demi couché sur l'horizon.
      const sr = Math.min(L, H) * .22;
      const s = ctx.createLinearGradient(0, horizon - sr, 0, horizon);
      s.addColorStop(0, '#ffd166'); s.addColorStop(1, '#ff3fa4');
      ctx.save();
      ctx.beginPath(); ctx.arc(L / 2, horizon, sr, Math.PI, 0); ctx.closePath(); ctx.clip();
      ctx.fillStyle = s; ctx.fillRect(0, horizon - sr, L, sr);
      ctx.fillStyle = '#2a0f45';
      for (let i = 0; i < 6; i++) ctx.fillRect(0, horizon - sr * (.15 + i * .13), L, 2 + i * 1.2);
      ctx.restore();
      // La lueur de l'horizon.
      const lh = ctx.createLinearGradient(0, horizon - 40, 0, horizon + 60);
      lh.addColorStop(0, 'rgba(255, 63, 164, 0)'); lh.addColorStop(.5, 'rgba(255, 63, 164, .35)'); lh.addColorStop(1, 'rgba(255, 63, 164, 0)');
      ctx.fillStyle = lh; ctx.fillRect(0, horizon - 40, L, 100);
      // La grille : des verticales qui convergent, des horizontales qui
      // avancent — l'espacement grandit vers le bas comme en perspective.
      ctx.strokeStyle = 'rgba(255, 63, 164, .55)'; ctx.lineWidth = 1;
      for (let i = -10; i <= 10; i++) {
        ctx.beginPath(); ctx.moveTo(L / 2 + i * 14, horizon); ctx.lineTo(L / 2 + i * L * .22, H); ctx.stroke();
      }
      const avance = (t * .012) % 1;
      for (let k = 0; k < 14; k++) {
        const p = ((k + avance) / 14) ** 2.2;
        const y = horizon + p * (H - horizon);
        ctx.globalAlpha = .25 + .6 * p;
        ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(L, y); ctx.stroke();
      }
      ctx.globalAlpha = 1;
    },
  };

  /* Aurore boréale : des voiles qui ondulent, verts puis violets, sur un ciel
   * d'étoiles fixes. Chaque voile est une bande verticale dont le haut suit
   * une somme de sinus — c'est ce qui donne le drapé. */
  EFFETS.aurore = (() => {
    let etoiles = [];
    const VOILES = [
      { base: .30, amp: .08, k: .010, v: .012, c: '93, 242, 166', a: .22 },
      { base: .38, amp: .10, k: .007, v: -.009, c: '60, 220, 200', a: .16 },
      { base: .46, amp: .07, k: .013, v: .015, c: '190, 110, 255', a: .13 },
    ];
    return {
      init() {
        etoiles = Array.from({ length: Math.round(L * H / 7000) },
                             () => ({ x: Math.random() * L, y: Math.random() * H * .7, r: hasard(.3, 1.3) }));
      },
      image(t) {
        const g = ctx.createLinearGradient(0, 0, 0, H);
        g.addColorStop(0, '#03060f'); g.addColorStop(.6, '#07101f'); g.addColorStop(1, '#0c1a2c');
        ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
        ctx.fillStyle = 'rgba(255,255,255,.7)';
        for (const e of etoiles) { ctx.beginPath(); ctx.arc(e.x, e.y, e.r, 0, Math.PI * 2); ctx.fill(); }
        for (const v of VOILES) {
          for (let x = 0; x < L; x += 5) {
            const haut = H * (v.base + v.amp * (Math.sin(x * v.k + t * v.v) + .5 * Math.sin(x * v.k * 2.3 - t * v.v * 1.7)));
            const long = H * (.18 + .08 * Math.sin(x * .02 + t * .01));
            const gr = ctx.createLinearGradient(0, haut, 0, haut + long);
            gr.addColorStop(0, `rgba(${v.c}, 0)`); gr.addColorStop(.25, `rgba(${v.c}, ${v.a})`); gr.addColorStop(1, `rgba(${v.c}, 0)`);
            ctx.fillStyle = gr; ctx.fillRect(x, haut, 5, long);
          }
        }
      },
    };
  })();

  /* Nuit d'été : des lucioles qui dérivent et respirent dans l'herbe. */
  EFFETS.lucioles = (() => {
    let mouches = [];
    return {
      init() {
        mouches = Array.from({ length: Math.round(26 * L * H / (390 * 844)) }, () => ({
          x: Math.random() * L, y: H * (.25 + Math.random() * .75),
          vx: hasard(-.4, .4), vy: hasard(-.25, .25), phase: Math.random() * Math.PI * 2, v: hasard(.03, .07), r: hasard(1.2, 2.4),
        }));
      },
      image(t) {
        const g = ctx.createLinearGradient(0, 0, 0, H);
        g.addColorStop(0, '#04100f'); g.addColorStop(.7, '#0a1a16'); g.addColorStop(1, '#13261c');
        ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
        // Des brins d'herbe en bas, en ombre.
        ctx.strokeStyle = 'rgba(20, 50, 35, .9)'; ctx.lineWidth = 2;
        for (let i = 0; i < L; i += 9) {
          const h = 30 + 40 * Math.abs(Math.sin(i * .37));
          ctx.beginPath(); ctx.moveTo(i, H); ctx.quadraticCurveTo(i + 4 + Math.sin(t * .02 + i) * 3, H - h / 2, i + 2, H - h); ctx.stroke();
        }
        for (const m of mouches) {
          const a = Math.max(0, Math.sin(m.phase + t * m.v)) ** 3;
          const halo = ctx.createRadialGradient(m.x, m.y, 0, m.x, m.y, m.r * 7);
          halo.addColorStop(0, `rgba(255, 230, 120, ${(.9 * a).toFixed(3)})`);
          halo.addColorStop(.3, `rgba(255, 220, 90, ${(.35 * a).toFixed(3)})`);
          halo.addColorStop(1, 'rgba(255, 220, 90, 0)');
          ctx.fillStyle = halo; ctx.beginPath(); ctx.arc(m.x, m.y, m.r * 7, 0, Math.PI * 2); ctx.fill();
          m.vx += hasard(-.04, .04); m.vy += hasard(-.03, .03);
          m.vx = Math.max(-.6, Math.min(.6, m.vx)); m.vy = Math.max(-.4, Math.min(.4, m.vy));
          m.x = (m.x + m.vx + L) % L; m.y = Math.max(H * .2, Math.min(H - 10, m.y + m.vy));
        }
      },
    };
  })();

  /* Savane : le soleil qui se couche, des acacias en ombre, des oiseaux. */
  EFFETS.savane = (() => {
    let oiseaux = [];
    let arbres = [];
    return {
      init() {
        oiseaux = Array.from({ length: 7 }, () => ({ x: Math.random() * L, y: H * hasard(.12, .45), v: hasard(.5, 1.1), s: hasard(5, 9), phase: Math.random() * 6 }));
        arbres = Array.from({ length: 4 }, (_, i) => ({ x: L * (.1 + i * .27) + hasard(-20, 20), h: hasard(55, 95), l: hasard(70, 130) }));
      },
      image(t) {
        const g = ctx.createLinearGradient(0, 0, 0, H);
        g.addColorStop(0, '#3a1c3f'); g.addColorStop(.35, '#b8432b'); g.addColorStop(.62, '#f29a3c'); g.addColorStop(.66, '#2a1612'); g.addColorStop(1, '#1a0d0a');
        ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
        // Le soleil, très lentement, s'enfonce et remonte.
        const sy = H * (.60 + .03 * Math.sin(t * .003));
        const halo = ctx.createRadialGradient(L / 2, sy, 0, L / 2, sy, L * .45);
        halo.addColorStop(0, 'rgba(255, 210, 120, .55)'); halo.addColorStop(1, 'rgba(255, 150, 60, 0)');
        ctx.fillStyle = halo; ctx.fillRect(0, 0, L, H * .66);
        ctx.save(); ctx.beginPath(); ctx.rect(0, 0, L, H * .655); ctx.clip();
        ctx.fillStyle = '#ffd97a'; ctx.beginPath(); ctx.arc(L / 2, sy, Math.min(L, H) * .13, 0, Math.PI * 2); ctx.fill();
        ctx.restore();
        // Le sol et les acacias, en ombre chinoise.
        ctx.fillStyle = '#1a0d0a'; ctx.fillRect(0, H * .655, L, H);
        for (const a of arbres) acacia(a.x, H * .655, a.h, a.l);
        // Quelques touffes d'herbe sèche au premier plan.
        ctx.strokeStyle = '#120806'; ctx.lineWidth = 1.2;
        for (let i = 0; i < L; i += 7) {
          const hh = 6 + 10 * Math.abs(Math.sin(i * .61));
          ctx.beginPath(); ctx.moveTo(i, H * .655 + 1); ctx.lineTo(i + Math.sin(i) * 3, H * .655 - hh); ctx.stroke();
        }
        // Les oiseaux : deux arcs, battement lent.
        ctx.strokeStyle = 'rgba(30, 10, 10, .9)'; ctx.lineWidth = 1.5;
        for (const o of oiseaux) {
          const b = Math.sin(t * .25 + o.phase) * o.s * .5;
          ctx.beginPath(); ctx.moveTo(o.x - o.s, o.y + b); ctx.quadraticCurveTo(o.x - o.s / 2, o.y - b, o.x, o.y); ctx.quadraticCurveTo(o.x + o.s / 2, o.y - b, o.x + o.s, o.y + b); ctx.stroke();
          o.x += o.v; if (o.x > L + 20) { o.x = -20; o.y = H * hasard(.12, .45); }
        }
      },
    };
  })();

  /* Un décor fixe : dessiné une fois à la taille, puis recopié tel quel. */
  function fixe(peint) {
    let fait = null;
    return {
      init() { fait = document.createElement('canvas'); fait.width = toile.width; fait.height = toile.height; const c2 = fait.getContext('2d'); c2.setTransform(toile.width / L, 0, 0, toile.height / H, 0, 0); peint(c2); },
      image() { ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.drawImage(fait, 0, 0); ctx.restore(); },
      fixe: true,
    };
  }

  /* Aquarelle : des taches de couleur diluées sur du papier. Rien ne bouge —
   * c'est un lavis, pas une animation. */
  EFFETS.aquarelle = fixe((c2) => {
    c2.fillStyle = '#fffdf8'; c2.fillRect(0, 0, L, H);
    const teintes = ['79,143,207', '232,131,121', '246,196,83', '98,184,142', '171,124,205', '240,150,190'];
    for (let i = 0; i < 14; i++) {
      const x = Math.random() * L, y = Math.random() * H, r = hasard(70, 170);
      const t = teintes[i % teintes.length];
      const g = c2.createRadialGradient(x + hasard(-20, 20), y + hasard(-20, 20), r * .2, x, y, r);
      g.addColorStop(0, `rgba(${t}, .28)`); g.addColorStop(.7, `rgba(${t}, .16)`); g.addColorStop(1, `rgba(${t}, 0)`);
      c2.fillStyle = g; c2.beginPath();
      // Un bord irrégulier : le rond parfait fait tache d'encre, pas aquarelle.
      for (let k = 0; k <= 24; k++) { const ang = k / 24 * Math.PI * 2; const rr = r * (.85 + .15 * Math.sin(k * 2.7 + i)); c2.lineTo(x + Math.cos(ang) * rr, y + Math.sin(ang) * rr); }
      c2.fill();
    }
    // Le grain du papier.
    for (let i = 0; i < L * H / 60; i++) { c2.fillStyle = `rgba(120, 100, 80, ${hasard(.02, .06).toFixed(3)})`; c2.fillRect(Math.random() * L, Math.random() * H, 1, 1); }
  });

  /* Lagon : la lumière qui danse au fond d'une eau claire. Deux nappes de
   * caustiques qui glissent l'une sur l'autre. */
  EFFETS.lagon = {
    init() {},
    image(t) {
      const g = ctx.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#bfeeee'); g.addColorStop(1, '#e4f7f5');
      ctx.fillStyle = g; ctx.fillRect(0, 0, L, H);
      ctx.lineWidth = 2; ctx.lineCap = 'round';
      for (const nappe of [{ k: .045, v: .03, d: 26, a: .5, dec: 0 }, { k: .03, v: -.02, d: 34, a: .35, dec: 13 }]) {
        ctx.strokeStyle = `rgba(255, 255, 255, ${nappe.a})`;
        for (let y = nappe.dec; y < H + 40; y += nappe.d) {
          ctx.beginPath();
          for (let x = 0; x <= L; x += 6) {
            const yy = y + Math.sin(x * nappe.k + t * nappe.v + y * .05) * 9 + Math.sin(x * nappe.k * 2.1 - t * nappe.v * 1.4) * 4;
            if (x === 0) ctx.moveTo(x, yy); else ctx.lineTo(x, yy);
          }
          ctx.stroke();
        }
      }
      // Les reflets, plus francs là où deux crêtes se croisent.
      ctx.fillStyle = 'rgba(255,255,255,.18)';
      for (let i = 0; i < 40; i++) { const x = (i * 97 + t * .7) % L, y = (i * 61 + t * .4) % H; ctx.beginPath(); ctx.ellipse(x, y, 10, 4, Math.sin(i), 0, Math.PI * 2); ctx.fill(); }
    },
  };

  /* Nébuleuse : des nuées de couleur fixes, et un champ d'étoiles qui dérive
   * devant, très lentement. */
  EFFETS.nebuleuse = (() => {
    const nuees = fixe((c2) => {
      c2.fillStyle = '#0d0a1f'; c2.fillRect(0, 0, L, H);
      const teintes = ['199,125,255', '255,110,170', '90,140,255', '120,220,255', '255,170,90'];
      for (let i = 0; i < 9; i++) {
        const x = Math.random() * L, y = Math.random() * H, r = hasard(90, 220);
        const g = c2.createRadialGradient(x, y, 0, x, y, r);
        const tn = teintes[i % teintes.length];
        g.addColorStop(0, `rgba(${tn}, .30)`); g.addColorStop(.5, `rgba(${tn}, .12)`); g.addColorStop(1, `rgba(${tn}, 0)`);
        c2.fillStyle = g; c2.fillRect(x - r, y - r, r * 2, r * 2);
      }
    });
    let etoiles = [];
    return {
      init() {
        nuees.init();
        etoiles = Array.from({ length: Math.round(L * H / 3200) }, () => ({ x: Math.random() * L, y: Math.random() * H, r: hasard(.3, 1.5), v: hasard(.03, .12), phase: Math.random() * 6, p: hasard(.02, .08) }));
      },
      image(t) {
        nuees.image();
        for (const e of etoiles) {
          const a = .5 + .5 * Math.sin(e.phase + t * e.p) ** 2;
          ctx.fillStyle = `rgba(255,255,255,${a.toFixed(3)})`;
          ctx.beginPath(); ctx.arc(e.x, e.y, e.r, 0, Math.PI * 2); ctx.fill();
          e.x -= e.v * e.r; if (e.x < 0) { e.x = L; e.y = Math.random() * H; }
        }
      },
    };
  })();

  /* ── le cycle de vie ──────────────────────────────────────────────────*/

  function dimensionne() {
    const dpr = Math.min(2, devicePixelRatio || 1);
    L = innerWidth; H = innerHeight;
    toile.width = Math.round(L * dpr);
    toile.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    effet.init();
  }

  function trame(t) {
    if (!actif) return;
    boucle = requestAnimationFrame(trame);
    if (t - derniere < CADENCE) return;
    derniere = t;
    temps += 1;
    effet.image(temps);
  }

  const sansAnimation = () => document.documentElement.classList.contains('sans-animation');

  function demarre(nom) {
    if (!EFFETS[nom]) { arrete(); return; }
    if (toile && effet === EFFETS[nom]) return;
    arrete();
    effet = EFFETS[nom];
    toile = document.createElement('canvas');
    toile.id = 'fond-anime';
    toile.setAttribute('aria-hidden', 'true');
    document.body.prepend(toile);
    document.documentElement.dataset.fond = nom;
    ctx = toile.getContext('2d', { alpha: false });
    dimensionne();
    addEventListener('resize', dimensionne);
    document.addEventListener('visibilitychange', visibilite);
    // Animations coupées : quelques images pour poser le décor, puis plus rien.
    if (sansAnimation()) {
      for (let i = 0; i < 40; i++) effet.image(++temps);
      return;
    }
    actif = true;
    boucle = requestAnimationFrame(trame);
  }

  function visibilite() {
    if (!toile) return;
    if (document.hidden) { actif = false; cancelAnimationFrame(boucle); }
    else if (!actif && !sansAnimation()) { actif = true; boucle = requestAnimationFrame(trame); }
  }

  function arrete() {
    if (!toile) return;
    actif = false;
    cancelAnimationFrame(boucle);
    removeEventListener('resize', dimensionne);
    document.removeEventListener('visibilitychange', visibilite);
    toile.remove();
    toile = null; ctx = null; effet = null;
    delete document.documentElement.dataset.fond;
  }

  return { demarre, arrete, actif: () => !!toile, EFFETS };
})();
