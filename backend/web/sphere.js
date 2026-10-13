/*
 * Le lancer de sphère, joué par-dessus la photo pendant l'analyse.
 *
 * Le site montrait un disque qui tourne. C'est honnête et ça ne dit rien : les
 * quinze secondes d'analyse passaient sans qu'il se produise quoi que ce soit.
 * L'application, elle, joue un geste — et c'est ce geste qui fait l'attente.
 *
 * **L'ordre suit le geste réel, pas l'analyse.** On vise, on lance, la sphère
 * secoue, puis on apprend le résultat :
 *
 *   0 → 0,9 s     le cercle de visée se resserre sur la bête
 *   0,9 → 2,15 s  la sphère traverse le cadre en arc, avec sa traînée
 *   2,2 s → …     elle secoue, en boucle, aussi longtemps que dure l'analyse
 *   à la réponse  elle s'illumine, ou s'ouvre et la bête s'échappe
 *
 * Faire partir la sphère à l'arrivée du verdict — ce qui paraît logique —
 * escamote le lancer en une fraction de seconde, à la fin, quand plus personne
 * ne regarde.
 *
 * **L'horloge est réelle**, pas une horloge d'animation : le déroulé ne doit
 * dépendre d'aucun réglage système, sous peine de défiler à une vitesse absurde
 * ou de ne pas apparaître du tout.
 */
const Sphere = (() => {
  'use strict';

  const VISEE = 0.9;
  const VOL = 1.25;          // durée du lancer lui-même
  const POSE = VISEE + VOL;  // la sphère touche le sol
  const SECOUSSE = 1.15;     // un aller-retour complet
  const FINALE = 0.9;        // illumination ou ouverture

  const ROUGE = '#e84c4c';
  const ENCRE = '#1b1d21';

  function arc(ctx, x, y, r, de, a, remplit, couleur, epaisseur) {
    ctx.beginPath();
    ctx.arc(x, y, r, de, a);
    if (remplit) { ctx.closePath(); ctx.fillStyle = couleur; ctx.fill(); }
    else { ctx.strokeStyle = couleur; ctx.lineWidth = epaisseur; ctx.stroke(); }
  }

  /* La sphère. `ouverture` écarte les deux moitiés, `lueur` l'entoure d'un
   * halo — la prise est acquise. */
  function sphere(ctx, x, y, r, { rotation = 0, lueur = 0, ouverture = 0, couleur }) {
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(rotation);

    // Une ombre portée la détache de la photo, qui peut être claire.
    ctx.beginPath();
    ctx.arc(0, 3, r + 1, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(0,0,0,.28)';
    ctx.fill();

    if (lueur > 0) {
      ctx.beginPath();
      ctx.arc(0, 0, r + 12 * lueur, 0, Math.PI * 2);
      ctx.fillStyle = couleur;
      ctx.globalAlpha = 0.55 * lueur;
      ctx.fill();
      ctx.globalAlpha = 1;
    }

    const ecart = ouverture * r * 1.5;
    ctx.save(); ctx.translate(0, -ecart);
    arc(ctx, 0, 0, r, Math.PI, Math.PI * 2, true, ROUGE);
    arc(ctx, 0, 0, r, Math.PI, Math.PI * 2, false, ENCRE, 2.5);
    ctx.restore();

    ctx.save(); ctx.translate(0, ecart);
    arc(ctx, 0, 0, r, 0, Math.PI, true, '#ffffff');
    arc(ctx, 0, 0, r, 0, Math.PI, false, ENCRE, 2.5);
    ctx.restore();

    if (ouverture < 0.1) {
      ctx.beginPath();
      ctx.moveTo(-r, 0); ctx.lineTo(r, 0);
      ctx.strokeStyle = ENCRE; ctx.lineWidth = 3; ctx.stroke();
      ctx.beginPath();
      ctx.arc(0, 0, r * 0.28, 0, Math.PI * 2);
      ctx.fillStyle = '#fff'; ctx.fill();
      ctx.strokeStyle = ENCRE; ctx.lineWidth = 2.5; ctx.stroke();
    }
    ctx.restore();
  }

  /* Le cercle de visée : un anneau fixe, un second qui vient l'épouser, et
   * quatre équerres. C'est ce qui dit « on regarde cette bête-là ». */
  function visee(ctx, cx, cy, l, t, couleur, opacite = 1) {
    const r = l * 0.28;
    ctx.lineWidth = 3;
    ctx.strokeStyle = `rgba(255,255,255,${0.85 * opacite})`;
    ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();

    // easeInOut, pour que l'anneau mobile arrive en se posant.
    const a = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
    ctx.globalAlpha = (0.3 + 0.6 * a) * opacite;
    ctx.strokeStyle = couleur;
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.arc(cx, cy, r + l * 0.55 * (1 - a), 0, Math.PI * 2);
    ctx.stroke();
    ctx.globalAlpha = 1;

    ctx.strokeStyle = `rgba(255,255,255,${0.9 * opacite})`;
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    for (const [sx, sy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
      const px = cx + sx * r * 0.96;
      const py = cy + sy * r * 0.96;
      ctx.beginPath();
      ctx.moveTo(px, py); ctx.lineTo(px - sx * 16, py);
      ctx.moveTo(px, py); ctx.lineTo(px, py - sy * 16);
      ctx.stroke();
    }
  }

  /* Les étoiles de capture : elles jaillissent, montent en spirale, s'éteignent.
   * L'angle avance pendant que le rayon grandit — sinon le bouquet paraît figé. */
  function etoiles(ctx, x, y, issue) {
    const combien = 7;
    for (let i = 0; i < combien; i++) {
      const angle = (i / combien) * Math.PI * 2 + issue * 1.9;
      const r = 26 + 58 * (1 - (1 - issue) ** 3);
      const px = x + Math.cos(angle) * r;
      const py = y + Math.sin(angle) * r * 0.72;
      const taille = 9 * (1 - issue * 0.55);
      const o = issue < 0.18 ? issue / 0.18 : 1 - (issue - 0.18) / 0.82;
      ctx.globalAlpha = Math.max(0, Math.min(1, o));
      ctx.fillStyle = '#fff';
      ctx.beginPath();
      for (let k = 0; k < 10; k++) {
        const rr = k % 2 === 0 ? taille : taille * 0.42;
        const aa = angle * 2 + (k / 10) * Math.PI * 2 - Math.PI / 2;
        const fx = px + Math.cos(aa) * rr;
        const fy = py + Math.sin(aa) * rr;
        k === 0 ? ctx.moveTo(fx, fy) : ctx.lineTo(fx, fy);
      }
      ctx.closePath(); ctx.fill();
      ctx.globalAlpha = 1;
    }
  }

  /* Lance l'animation sur un canevas.
   *
   * Rend un objet : `.termine(reussi)` annonce le verdict et déclenche la
   * scène finale ; `.arrete()` coupe tout. `surFin` est appelé quand la scène
   * finale est jouée — c'est le moment de montrer le résultat. */
  function lance(toile, { couleur = '#3fae5a', surFin = null } = {}) {
    const ctx = toile.getContext('2d');
    const densite = Math.min(devicePixelRatio || 1, 2);
    const depart = performance.now();

    let verdict = null;      // null tant que le moteur n'a pas tranché
    let debutFin = null;
    let vivant = true;
    let annonce = false;

    function dimensionne() {
      const l = Math.round(toile.clientWidth * densite);
      const h = Math.round(toile.clientHeight * densite);
      if (toile.width !== l || toile.height !== h) {
        toile.width = l; toile.height = h;
      }
    }

    function trame(maintenant) {
      if (!vivant || !toile.isConnected) return;
      dimensionne();
      const l = toile.width;
      const h = toile.height;
      const t = (maintenant - depart) / 1000;

      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, l, h);
      ctx.scale(densite, densite);
      const L = l / densite;
      const H = h / densite;

      const cx = L / 2;
      const cy = H * 0.44;          // la bête, un peu au-dessus du centre
      const dx = L * 0.12;          // d'où part la sphère : en bas à gauche
      const dy = H * 0.94;

      if (t < VISEE) {
        visee(ctx, cx, cy, L, t / VISEE, couleur);
      } else if (t < POSE) {
        const v = (t - VISEE) / VOL;
        // La visée s'efface pendant que la sphère traverse.
        visee(ctx, cx, cy, L, 1, couleur, Math.max(0, 1 - v * 2.2));
        // Un ventre d'arc : sans lui, le lancer glisse au sol et ne se lit pas.
        const px = dx + (cx - dx) * v;
        const py = dy + (cy - dy) * v - Math.sin(v * Math.PI) * H * 0.46;
        // La traînée, quelques positions en arrière et de plus en plus pâle.
        for (let k = 6; k >= 1; k--) {
          const u = Math.max(0, v - k * 0.035);
          ctx.globalAlpha = 0.06 * (7 - k);
          ctx.beginPath();
          ctx.arc(dx + (cx - dx) * u,
                  dy + (cy - dy) * u - Math.sin(u * Math.PI) * H * 0.46,
                  22 - k * 1.6, 0, Math.PI * 2);
          ctx.fillStyle = '#fff'; ctx.fill();
        }
        ctx.globalAlpha = 1;
        sphere(ctx, px, py, 26, { rotation: v * Math.PI * 3, couleur });
      } else if (verdict === null) {
        // Deux basculements par tour, séparés d'un temps mort : c'est le rythme
        // qui fait durer le doute.
        const s = ((t - POSE) % SECOUSSE) / SECOUSSE;
        const angle = s < 0.62 ? Math.sin((s / 0.62) * Math.PI * 2) * 0.5 : 0;
        ctx.save();
        ctx.translate(cx, cy + 22);
        ctx.rotate(angle);
        ctx.translate(-cx, -(cy + 22));
        sphere(ctx, cx, cy, 28, { couleur });
        ctx.restore();
      } else {
        const issue = Math.min((maintenant - debutFin) / 1000 / FINALE, 1);
        if (verdict) {
          ctx.globalAlpha = 1 - issue;
          ctx.strokeStyle = couleur;
          ctx.lineWidth = 5 * (1 - issue);
          ctx.beginPath();
          ctx.arc(cx, cy, 32 + 90 * issue, 0, Math.PI * 2);
          ctx.stroke();
          ctx.globalAlpha = 1;
          etoiles(ctx, cx, cy, issue);
          sphere(ctx, cx, cy, 28, { lueur: 1 - issue * 0.5, couleur });
        } else {
          sphere(ctx, cx, cy, 28, { ouverture: issue, couleur });
          ctx.globalAlpha = (1 - issue) * 0.5;
          ctx.beginPath();
          ctx.arc(cx, cy, 20 + 70 * issue, 0, Math.PI * 2);
          ctx.fillStyle = '#fff'; ctx.fill();
          ctx.globalAlpha = 1;
        }
        if (issue >= 1 && !annonce) { annonce = true; surFin?.(); }
      }
      requestAnimationFrame(trame);
    }
    requestAnimationFrame(trame);

    return {
      /* Le verdict est arrivé. La scène finale ne démarre pas avant que la
       * sphère soit posée : sinon l'analyse la plus rapide ferait exploser la
       * sphère en plein vol, ce qui n'a aucun sens. */
      termine(reussi) {
        if (verdict !== null) return;
        const restant = Math.max(0, POSE + 0.35 - (performance.now() - depart) / 1000);
        setTimeout(() => {
          verdict = !!reussi;
          debutFin = performance.now();
        }, restant * 1000);
      },
      arrete() { vivant = false; },
    };
  }

  return { lance };
})();
