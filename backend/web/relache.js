/*
 * La relâche : la sphère s'ouvre et la bête s'enfuit.
 *
 * L'inverse exact de la capture, portée de `relacher.dart`. La sphère tombe
 * sur la photo, rebondit, s'entrouvre en projetant des rais rouges, et la
 * photo s'éloigne en s'effaçant — comme un animal qui détale. Mêmes temps
 * que dans l'application, à la milliseconde :
 *
 *   0,00 – 0,45  la sphère descend au centre et rebondit
 *   0,45 – 1,00  elle s'ouvre, les rais jaillissent, l'éclair monte
 *   0,55 – 1,00  la photo s'éloigne et disparaît
 *
 * Le rendu suit l'horloge réelle (`performance.now`), pas un compteur de
 * trames : à 30 comme à 120 images par seconde, la relâche dure 1,7 s.
 *
 * Pourquoi un module à part plutôt qu'un bout d'`app.js` : comme le lancer et
 * les confettis, c'est un dessin autonome qui ne lit pas l'état de la page.
 * On lui donne l'image à faire fuir et une fonction à appeler à la fin.
 */
const Relache = (() => {
  'use strict';

  const DUREE = 1700;
  const ROUGE = '#e84c4c';
  const BLANC = '#f7f7f8';
  const ENCRE = '#17181c';

  const easeInCubic = (t) => t * t * t;
  const easeOut = (t) => 1 - Math.pow(1 - t, 3);

  /* La sphère, entière ou entrouverte. Deux demi-disques qui s'écartent, et
   * la ceinture avec son bouton tant qu'elle est fermée. */
  function sphere(ctx, x, y, r, ouverture) {
    const ecart = ouverture * r * 2.6;
    ctx.save();
    ctx.translate(x, y);

    ctx.save();
    ctx.translate(0, -ecart);
    ctx.beginPath(); ctx.arc(0, 0, r, Math.PI, Math.PI * 2); ctx.closePath();
    ctx.fillStyle = ROUGE; ctx.fill();
    ctx.lineWidth = 3; ctx.strokeStyle = ENCRE; ctx.stroke();
    ctx.restore();

    ctx.save();
    ctx.translate(0, ecart);
    ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI); ctx.closePath();
    ctx.fillStyle = BLANC; ctx.fill();
    ctx.lineWidth = 3; ctx.strokeStyle = ENCRE; ctx.stroke();
    ctx.restore();

    if (ouverture === 0) {
      ctx.beginPath(); ctx.moveTo(-r, 0); ctx.lineTo(r, 0);
      ctx.lineWidth = 6; ctx.strokeStyle = ENCRE; ctx.stroke();
      ctx.beginPath(); ctx.arc(0, 0, r * .30, 0, Math.PI * 2);
      ctx.fillStyle = ENCRE; ctx.fill();
      ctx.beginPath(); ctx.arc(0, 0, r * .20, 0, Math.PI * 2);
      ctx.fillStyle = BLANC; ctx.fill();
    }
    ctx.restore();
  }

  /* Les rais de lumière, façon décharge : des fuseaux fins qui partent du
   * centre, de longueurs inégales pour éviter l'effet de roue dentée. La
   * variation est déterministe — même motif à chaque relâche, mais qui ne
   * paraît pas régulier. */
  function rais(ctx, cx, cy, largeur, ouverture, couleur) {
    const combien = 16;
    const longueur = largeur * (.18 + .62 * easeOut(ouverture));
    const opacite = Math.max(0, Math.min(1, ouverture < .3 ? 1 : 1 - (ouverture - .3) / .7));
    ctx.lineCap = 'round';
    for (let i = 0; i < combien; i++) {
      const angle = i / combien * Math.PI * 2 + ouverture * .35;
      const facteur = .55 + .45 * ((i * 37) % 11) / 10;
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(angle) * 26, cy + Math.sin(angle) * 26);
      ctx.lineTo(cx + Math.cos(angle) * longueur * facteur,
                 cy + Math.sin(angle) * longueur * facteur);
      ctx.lineWidth = (i % 2 === 0 ? 4.5 : 2.5) * (1 - ouverture * .5);
      ctx.strokeStyle = i % 2 === 0 ? ROUGE : couleur;
      ctx.globalAlpha = opacite * .9;
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  function peint(ctx, l, h, t, couleur) {
    ctx.clearRect(0, 0, l, h);
    const cx = l / 2;
    const cy = h * .46;

    if (t < .45) {
      // Descente puis rebond : la sphère arrive et se pose.
      const avance = t / .45;
      const chute = easeInCubic(avance);
      const y = -60 + (cy + 60) * chute;
      const rebond = avance > .88 ? Math.sin((avance - .88) / .12 * Math.PI) * 8 : 0;
      sphere(ctx, cx, y - rebond, 34, 0);
      return;
    }

    const ouverture = Math.max(0, Math.min(1, (t - .45) / .55));
    rais(ctx, cx, cy, l, ouverture, couleur);

    // L'éclair blanc au moment précis de l'ouverture.
    if (ouverture < .45) {
      const e = ouverture / .45;
      ctx.beginPath();
      ctx.arc(cx, cy, 40 + l * .9 * e, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(255,255,255,${((1 - e) * .85).toFixed(3)})`;
      ctx.fill();
    }
    // Les deux moitiés s'écartent et sortent du champ.
    if (ouverture < .8) sphere(ctx, cx, cy, 34, ouverture / .8);
  }

  /* Joue la relâche par-dessus `img`, puis appelle `surFin`.
   *
   * Le canevas se pose sur l'image en absolu et prend exactement sa taille ;
   * l'image elle-même rétrécit et s'efface à partir de 0,55 s, comme dans
   * l'application. Tout est retiré à la fin : il ne reste rien à nettoyer. */
  function joue(img, { couleur = '#0ea5a4', surFin } = {}) {
    if (!img || !img.parentElement) { surFin?.(); return; }
    const parent = img.parentElement;
    const r = img.getBoundingClientRect();
    const pr = parent.getBoundingClientRect();

    const toile = document.createElement('canvas');
    const dpr = window.devicePixelRatio || 1;
    toile.width = Math.round(r.width * dpr);
    toile.height = Math.round(r.height * dpr);
    toile.className = 'relache';
    toile.style.cssText = `left:${r.left - pr.left}px;top:${r.top - pr.top}px;`
                        + `width:${r.width}px;height:${r.height}px`;
    if (getComputedStyle(parent).position === 'static') parent.style.position = 'relative';
    parent.appendChild(toile);
    const ctx = toile.getContext('2d');
    ctx.scale(dpr, dpr);

    img.style.transition = 'none';
    img.style.transformOrigin = 'center';
    const origine = performance.now();
    let vibre = false;

    const trame = (maintenant) => {
      const t = Math.min(1, (maintenant - origine) / DUREE);
      if (!vibre && t >= .45) { vibre = true; navigator.vibrate?.(18); }
      // La photo reste entière jusqu'à l'ouverture, puis s'éloigne et s'efface.
      const fuite = Math.max(0, Math.min(1, (t - .55) / .45));
      img.style.opacity = String(1 - fuite);
      img.style.transform = `scale(${1 - .22 * fuite})`;
      peint(ctx, r.width, r.height, t, couleur);
      if (t < 1) { requestAnimationFrame(trame); return; }
      toile.remove();
      surFin?.();
    };
    requestAnimationFrame(trame);
  }

  return { joue };
})();
