/*
 * La fête qui suit une découverte, jouée par-dessus la page.
 *
 * Le site annonçait une nouvelle espèce par une ligne de texte grise. Trouver
 * une bête qu'on n'a jamais vue est pourtant le seul moment du jeu qui mérite
 * qu'on lève les yeux — et plus elle est rare, plus ça doit se voir.
 *
 * **Pas de nouvel écran.** Les confettis tombent sur le contenu déjà affiché :
 * le résultat reste lisible pendant l'animation, et on n'a rien à refermer.
 *
 * **Le réglage suit la rareté**, comme dans l'application. Ce n'est pas
 * seulement une histoire de nombre : les qualités communes font pleuvoir des
 * confettis, les rares les font jaillir du centre. Les paliers discrets
 * compensent leur petit nombre par de plus gros morceaux — trois confettis
 * minuscules ne se voient pas, trois gros si.
 */
const Fete = (() => {
  'use strict';

  const REGLAGES = {
    1: { nombre: 110, calibre: 16, vitesse: 0.55, explosion: false, halo: false,
         titre: 'Trouvé',       couleurs: ['#9aa1ac', '#7d8590'] },
    2: { nombre: 130, calibre: 16, vitesse: 0.60, explosion: false, halo: false,
         titre: 'Trouvé',       couleurs: ['#3fae5a', '#2e9e4a'] },
    3: { nombre: 150, calibre: 15, vitesse: 0.75, explosion: false, halo: false,
         titre: 'Belle prise',  couleurs: ['#3b82f6', '#3fae5a', '#1d6fe0'] },
    4: { nombre: 130, calibre: 13, vitesse: 1.00, explosion: true, halo: false,
         titre: 'Rare !',       couleurs: ['#9b51e0', '#3b82f6', '#7b2fbf', '#1d6fe0'] },
    5: { nombre: 110, calibre: 12, vitesse: 1.25, explosion: true, halo: true,
         titre: 'Légendaire !', couleurs: ['#e8a317', '#ffd76a', '#fff3c4', '#c97f00'] },
  };

  let toile = null;
  let vivant = false;

  function prepare() {
    if (toile) return toile;
    toile = document.createElement('canvas');
    toile.className = 'toile-fete';
    document.body.appendChild(toile);
    return toile;
  }

  /* `qualite` va de 1 (commun) à 5 (légendaire). `sousTitre` nomme la bête. */
  function fete(qualite, sousTitre = '') {
    const r = REGLAGES[Math.max(1, Math.min(5, qualite | 0))] || REGLAGES[1];
    const t = prepare();
    const ctx = t.getContext('2d');
    const densite = Math.min(devicePixelRatio || 1, 2);

    t.width = Math.round(innerWidth * densite);
    t.height = Math.round(innerHeight * densite);
    const L = innerWidth;
    const H = innerHeight;

    // Les particules. Chacune tombe ou jaillit, tourne sur elle-même et
    // s'efface : trois mouvements distincts, sinon le tout paraît plaqué.
    const parts = [];
    for (let i = 0; i < r.nombre; i++) {
      const a = Math.random() * Math.PI * 2;
      const v = (0.6 + Math.random() * 0.8) * r.vitesse;
      parts.push({
        x: r.explosion ? L / 2 : Math.random() * L,
        y: r.explosion ? H * 0.42 : -Math.random() * H * 0.4,
        vx: r.explosion ? Math.cos(a) * v * 420 : (Math.random() - 0.5) * 90,
        vy: r.explosion ? Math.sin(a) * v * 420 : (120 + Math.random() * 220) * r.vitesse,
        taille: r.calibre * (0.55 + Math.random() * 0.75),
        angle: Math.random() * Math.PI * 2,
        tourne: (Math.random() - 0.5) * 7,
        couleur: r.couleurs[(Math.random() * r.couleurs.length) | 0],
        // 0 rectangle, 1 disque, 2 étoile — les étoiles sont réservées à l'or.
        forme: qualite >= 5 ? (Math.random() < 0.45 ? 2 : Math.random() < 0.5 ? 1 : 0)
                            : (Math.random() < 0.5 ? 0 : 1),
      });
    }

    const bandeau = document.createElement('div');
    bandeau.className = `bandeau-fete q${qualite}${r.halo ? ' halo' : ''}`;
    bandeau.innerHTML = `<b>${r.titre}</b>${
      sousTitre ? `<span>${sousTitre}</span>` : ''}`;
    document.body.appendChild(bandeau);

    const depart = performance.now();
    const DUREE = 2600;
    vivant = true;

    // On endort les autres boucles : une pluie de cent cinquante particules et
    // trente vignettes animées en même temps, c'est là que ça saccade.
    Media.endors();
    let rendu = false;
    const fini = () => {
      if (rendu) return;
      rendu = true;
      vivant = false;
      bandeau.remove();
      ctx.clearRect(0, 0, t.width, t.height);
      Media.reveilleTout();
    };

    let precedent = depart;
    function trame(now) {
      if (!vivant) return;
      const dt = Math.min((now - precedent) / 1000, 0.05);
      precedent = now;
      const age = (now - depart) / DUREE;
      if (age >= 1) { fini(); return; }

      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, t.width, t.height);
      ctx.scale(densite, densite);
      // Les particules s'effacent sur le dernier tiers : disparaître d'un coup
      // laisse une trace nette à l'écran, comme un défaut d'affichage.
      ctx.globalAlpha = age < 0.66 ? 1 : 1 - (age - 0.66) / 0.34;

      for (const p of parts) {
        p.vy += 620 * dt;              // la pesanteur
        p.vx *= 1 - 1.1 * dt;          // le frottement de l'air
        p.vy *= 1 - 0.35 * dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.angle += p.tourne * dt;
        if (p.y > H + 40) continue;

        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.angle);
        ctx.fillStyle = p.couleur;
        if (p.forme === 0) {
          ctx.fillRect(-p.taille / 2, -p.taille / 4, p.taille, p.taille / 2);
        } else if (p.forme === 1) {
          ctx.beginPath();
          ctx.arc(0, 0, p.taille / 2, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.beginPath();
          for (let k = 0; k < 10; k++) {
            const rr = k % 2 === 0 ? p.taille * 0.6 : p.taille * 0.26;
            const aa = (k / 10) * Math.PI * 2 - Math.PI / 2;
            const fx = Math.cos(aa) * rr;
            const fy = Math.sin(aa) * rr;
            k === 0 ? ctx.moveTo(fx, fy) : ctx.lineTo(fx, fy);
          }
          ctx.closePath(); ctx.fill();
        }
        ctx.restore();
      }
      ctx.globalAlpha = 1;
      requestAnimationFrame(trame);
    }
    requestAnimationFrame(trame);

    // Un garde-fou : si l'onglet passe en arrière-plan, les trames s'arrêtent
    // et la boucle ne se terminerait jamais d'elle-même — la page resterait
    // endormie, avec un bandeau au milieu.
    setTimeout(fini, DUREE + 600);
  }

  return { fete };
})();
