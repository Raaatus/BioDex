/*
 * Ce qui bouge : l'attente qui tourne, et les objets qu'on fait pivoter.
 *
 * Un seul mécanisme pour les deux, parce que c'est le même problème. Les images
 * sont rangées côte à côte dans une planche de tuiles, produite une fois par
 * `backend/outils/apercu_modele.py`. On en dessine une
 * à la fois sur un canvas.
 *
 * Pourquoi pas un GIF pour l'attente : dans l'application Android, le décodeur
 * d'images animées refusait de l'animer alors que le fichier était
 * irréprochable — 45 images, 45 blocs de contrôle, délai de 100 ms. Plutôt que
 * de dépendre de l'humeur d'un décodeur, on dessine nous-mêmes. Le web n'a pas
 * ce défaut, mais deux mécanismes pour la même chose en auraient fait diverger
 * un le jour où on touche l'autre.
 *
 * Pourquoi pas un vrai moteur 3D pour la grenouille : il faudrait WebGL, un
 * chargeur glTF et une boucle de rendu, pour un objet de cinquante pixels dans
 * un bandeau. Vingt-quatre images pré-rendues pèsent 51 Ko et tournent au
 * doigt.
 *
 * L'application s'en sert en posant des `<canvas>` dans son HTML, puis en
 * appelant `Media.reveille()`. Le rendu de l'app remplace le DOM entier à
 * chaque fois : les canvas d'avant disparaissent, leurs boucles s'arrêtent
 * toutes seules parce qu'on vérifie `isConnected` à chaque trame.
 */
const Media = (() => {
  const PLANCHES = new Map();

  /* Une planche est chargée une fois puis partagée. Sans ce cache, chaque
   * rendu du dex redemanderait la même image au serveur — et le rendu est
   * fréquent. */
  function planche(url) {
    if (!PLANCHES.has(url)) {
      PLANCHES.set(url, new Promise((resout) => {
        const img = new Image();
        img.onload = () => resout(img);
        // On résout quand même en cas d'échec : un canvas qui ne dessine rien
        // vaut mieux qu'une promesse qui ne se règle jamais et retient tout.
        img.onerror = () => resout(null);
        img.src = url;
      }));
    }
    return PLANCHES.get(url);
  }

  /* Le rapport entre pixels CSS et pixels réels. Sans lui, tout est flou sur
   * un écran d'iPhone. */
  // Un canevas de vignette ne dépasse jamais cette taille en pixels CSS.
  //
  // C'est un garde-fou, pas une cible : les vignettes font entre 40 et 200 px,
  // et le plus grand usage — la silhouette d'une fiche de succès — en fait 150.
  // Au-delà, c'est qu'une mise en page a dérapé, et il vaut mieux une vignette
  // un peu pixelisée qu'une grenouille de deux mille pixels en travers de
  // l'écran.
  const COTE_MAX = 320;

  function ajuste(toile) {
    const d = window.devicePixelRatio || 1;
    // Le plafond n'est pas décoratif. La largeur d'affichage d'un canevas que
    // rien ne borne en CSS *est* sa largeur intrinsèque : la trame suivante
    // relit cette valeur et la remultiplie par la densité de l'écran, si bien
    // que le canevas double à chaque trame — 192, 384, 768, et ainsi de suite.
    // La contrainte de largeur vit dans la feuille de style (`.modele`), et ce
    // plafond est là pour le jour où une règle manquera.
    //
    // On ne pose surtout pas de `style.width` ici : une taille en ligne
    // l'emporte sur la feuille de style, et fige la vignette à ce qu'elle
    // mesurait au moment de l'écriture — y compris quand c'est absurde.
    const brut = toile.clientWidth || parseFloat(toile.dataset.taille) || 56;
    const l = Math.min(brut, COTE_MAX);
    if (toile.width !== Math.round(l * d)) {
      toile.width = Math.round(l * d);
      toile.height = Math.round(l * d);
    }
    return { cote: toile.width };
  }

  function dessineTuile(ctx, img, indice, colonnes, x, y, cote) {
    const tuile = img.width / colonnes;
    ctx.drawImage(
      img,
      (indice % colonnes) * tuile, Math.floor(indice / colonnes) * tuile,
      tuile, tuile,
      x, y, cote, cote,
    );
  }

  /* ─────────────────────────── la mise en veille ────────────────────────
   *
   * La page des succès dessine trente canevas animés : trente planches de
   * 800×800 redécoupées soixante fois par seconde. C'est supportable tant que
   * c'est tout ce qui tourne. Ça ne l'est plus dès qu'on ouvre un cristal — un
   * lancer de rayon à soixante-quatre pas par pixel — ou un modèle 3D, qui
   * réclament le processeur graphique pour eux seuls.
   *
   * On ne les arrête donc pas un par un : un drapeau, et toutes les boucles se
   * rendent la main à la trame suivante. Elles repartent où elles en étaient,
   * puisque la position est calculée depuis l'horloge et non comptée en trames.
   *
   * `endormi` compte au lieu d'être un booléen : une vue 3D peut s'ouvrir
   * par-dessus une autre, et le premier réveil ne doit pas rendre la main
   * pendant que la seconde tourne encore.
   */
  let endormi = 0;
  const dormeurs = new Set();

  function endors() { endormi += 1; }

  function relanceLesDormeurs() {
    endormi = Math.max(0, endormi - 1);
    if (endormi) return;
    // Les boucles suspendues se sont arrêtées : on les relance.
    for (const relance of dormeurs) relance();
    dormeurs.clear();
  }

  /* Vrai si la boucle doit s'arrêter là. Elle se réinscrira pour le réveil. */
  function enPause(relance) {
    if (!endormi) return false;
    dormeurs.add(relance);
    return true;
  }

  /* ------------------------------------------------------------- attente */

  function anime(toile) {
    const url = toile.dataset.planche;
    const images = +toile.dataset.images || 30;
    const colonnes = +toile.dataset.colonnes || 6;
    // Le sujet tourne lentement — c'est un manège. L'anneau, lui, va vite :
    // c'est lui qui dit « ça travaille », et un sujet à 2,4 secondes le tour ne
    // le dit pas sur une attente d'une demi-seconde.
    const tour = +toile.dataset.tour || 2400;
    const tourAnneau = 1100;
    const anneau = toile.dataset.anneau !== 'non';
    const fond = toile.dataset.fond || '';
    const trait = toile.dataset.trait || '#0ea5a4';

    planche(url).then((img) => {
      const ctx = toile.getContext('2d');
      const depart = performance.now();
      const trame = (t) => {
        if (!toile.isConnected) return;   // l'app a redessiné : on s'arrête
        if (enPause(() => requestAnimationFrame(trame))) return;
        const { cote } = ajuste(toile);
        const rayon = cote / 2;
        ctx.clearRect(0, 0, cote, cote);

        if (fond) {
          ctx.beginPath();
          ctx.arc(rayon, rayon, rayon, 0, Math.PI * 2);
          ctx.fillStyle = fond;
          ctx.fill();
        }
        if (img) {
          // Le sujet occupe l'intérieur du disque et non tout le carré : sinon
          // ses pieds sortent du cercle quand il pivote de profil.
          const marge = fond ? rayon * 0.10 : 0;
          const i = Math.floor(((t - depart) % tour) / tour * images) % images;
          dessineTuile(ctx, img, i, colonnes, marge, marge, cote - marge * 2);
        }
        if (anneau) {
          const p = ((t - depart) % tourAnneau) / tourAnneau;
          ctx.beginPath();
          ctx.lineWidth = Math.max(cote * 0.045, 2.5);
          ctx.lineCap = 'round';
          ctx.strokeStyle = trait;
          // Un quart de tour, pas un cercle entier : c'est le vide qui rend le
          // mouvement visible.
          ctx.arc(rayon, rayon, rayon - ctx.lineWidth / 2,
            p * Math.PI * 2, p * Math.PI * 2 + Math.PI / 2);
          ctx.stroke();
        }
        requestAnimationFrame(trame);
      };
      requestAnimationFrame(trame);
    });
  }

  /* ------------------------------------------------------------- tourneur */

  function tourne(toile) {
    const url = toile.dataset.planche;
    const images = +toile.dataset.images || 24;
    const colonnes = +toile.dataset.colonnes || 5;
    const tour = +toile.dataset.tour || 6000;
    const auto = toile.dataset.auto !== 'non';
    const noir = toile.dataset.noir === 'oui';
    const manipulable = toile.dataset.doigt === 'oui';

    let position = 0;
    let tenu = false;
    let dernierX = 0;

    if (manipulable) {
      const tire = (x) => {
        if (!tenu) return;
        // Une largeur balayée fait un tour et demi : assez pour faire le tour
        // d'un pouce, pas au point que le moindre frémissement l'emballe.
        position = (position + 1.5 * (x - dernierX) / (toile.clientWidth || 1) + 1) % 1;
        dernierX = x;
      };
      const lache = () => { tenu = false; };
      toile.addEventListener('pointerdown', (e) => {
        tenu = true;
        dernierX = e.clientX;
        toile.setPointerCapture(e.pointerId);
      });
      toile.addEventListener('pointermove', (e) => {
        if (tenu) { tire(e.clientX); e.preventDefault(); }
      });
      toile.addEventListener('pointerup', lache);
      toile.addEventListener('pointercancel', lache);
      // `touch-action` empêche le navigateur de prendre le geste pour un
      // défilement : sans lui, la page bouge et l'objet reste immobile.
      toile.style.touchAction = 'pan-y';
    }

    // La planche de rotation ne se charge que si l'objet doit vraiment tourner.
    //
    // Une planche fait 800×800, soit 2,4 Mo une fois décodée en mémoire — pour
    // n'afficher qu'*une* de ses vingt-quatre vues tant que la vignette est
    // immobile. La grille des succès en pose quatre-vingt-deux : deux cents
    // mégaoctets d'images décodées, au-delà de ce qu'iOS accorde à une page,
    // qui laissait l'écran des succès vide sur iPhone. L'image fixe fait le
    // même travail pour huit mégaoctets à elles toutes, et à la résolution
    // identique — c'est très exactement une vue de la planche.
    //
    // La planche arrive donc à la demande : quand l'objet tourne tout seul, ou
    // au premier doigt posé dessus.
    const fixe = url.replace('_tour.webp', '_apercu.webp');
    const ctx = toile.getContext('2d');
    let rotation = null;   // la planche, une fois qu'on en a eu besoin
    let immobile = null;   // l'image fixe, légère
    let demandee = false;  // la planche a-t-elle déjà été réclamée ?
    let precedent = performance.now();
    let anime_ = false;    // une boucle d'animation est-elle en cours ?

    function peint(cote) {
      ctx.clearRect(0, 0, cote, cote);
      if (rotation) {
        const i = Math.floor(position * images) % images;
        dessineTuile(ctx, rotation, i, colonnes, 0, 0, cote);
      } else if (immobile) {
        ctx.drawImage(immobile, 0, 0, cote, cote);
      } else {
        return;
      }
      if (noir) {
        // `source-atop` ne peint que là où il y a déjà quelque chose : la
        // silhouette reste exacte, trous entre les pattes compris.
        ctx.globalCompositeOperation = 'source-atop';
        ctx.fillStyle = '#141414';
        ctx.fillRect(0, 0, cote, cote);
        ctx.globalCompositeOperation = 'source-over';
      }
    }

    const trame = (t) => {
      if (!toile.isConnected) { anime_ = false; return; }
      if (enPause(() => { precedent = performance.now();
                          requestAnimationFrame(trame); })) return;
      const { cote } = ajuste(toile);
      if (auto && !tenu) position = (position + (t - precedent) / tour) % 1;
      precedent = t;
      peint(cote);
      // On ne redemande une trame que si quelque chose bouge encore. Une
      // vignette figée qui se repeignait soixante fois par seconde, multipliée
      // par quatre-vingt-deux, chauffait le téléphone sans rien montrer de plus.
      if (auto || tenu) requestAnimationFrame(trame);
      else anime_ = false;
    };

    function relance() {
      if (anime_) return;
      anime_ = true;
      precedent = performance.now();
      requestAnimationFrame(trame);
    }

    function chargeLaRotation() {
      if (demandee) return;
      demandee = true;
      planche(url).then((img) => { rotation = img; relance(); });
    }

    if (auto) {
      chargeLaRotation();
    } else {
      planche(fixe).then((img) => { immobile = img; relance(); });
      // Le doigt réclame la vraie planche : sans elle, rien à faire tourner.
      if (manipulable) {
        toile.addEventListener('pointerdown', chargeLaRotation, { once: true });
      }
    }

    // Une vignette qui ne se repeint plus doit malgré tout se redessiner quand
    // sa taille change : sans cela elle resterait floue après une rotation de
    // l'écran ou un changement de mise en page.
    if (typeof ResizeObserver === 'function') {
      new ResizeObserver(() => relance()).observe(toile);
    }
  }

  /* --------------------------------------------------------------- public */

  return {
    /* À appeler après chaque rendu. Les canvas neufs démarrent, ceux d'avant
     * se sont arrêtés seuls en quittant le document. */
    reveille() {
      document.querySelectorAll('canvas[data-planche]:not([data-vivant])')
        .forEach((toile) => {
          toile.dataset.vivant = '1';
          if (toile.dataset.role === 'tourneur') tourne(toile);
          else anime(toile);
        });
    },

    /* L'attente, en HTML. `taille` en pixels CSS. */
    chargement(taille = 92, message = '') {
      // La couleur est lue sur le thème courant : figer un gris clair ferait
      // une tache blanche au milieu d'une page en thème sombre.
      const fond = getComputedStyle(document.documentElement)
        .getPropertyValue('--fond-2').trim() || '#e9ecef';
      return `<div class="attente">
        <canvas class="pastille-attente" data-planche="media/chargement.webp"
                data-images="30" data-colonnes="6" data-taille="${taille}"
                data-fond="${fond}"
                style="width:${taille}px;height:${taille}px"></canvas>
        ${message ? `<p class="attente-mot">${message}</p>` : ''}
      </div>`;
    },

    /* Un objet qui tourne.
     *
     * `modele` choisit la planche. Elle valait `grenouille` pour tout le
     * monde tant qu'il n'existait qu'un fichier ; maintenant que chaque succès
     * a le sien, une grille qui montrerait trente fois la même grenouille
     * n'apprendrait rien de ce qu'il y a à gagner — et c'est précisément ce
     * que la silhouette d'un succès verrouillé doit dire. */
    /* Suspend toutes les boucles de dessin, le temps d'une animation ou d'une
     * vue 3D qui a besoin du processeur graphique pour elle seule. À rendre
     * avec `reveilleTout()`, systématiquement — un `finally` de préférence,
     * sinon la page reste figée. */
    endors,
    reveilleTout: relanceLesDormeurs,

    modele(taille = 56, options = {}) {
      const o = Object.assign(
        { doigt: false, auto: true, noir: false, classe: '',
          modele: 'grenouille' }, options);
      return `<canvas class="modele ${o.classe}" data-role="tourneur"
        data-planche="media/${o.modele}_tour.webp"
        data-images="24" data-colonnes="5"
        data-doigt="${o.doigt ? 'oui' : 'non'}"
        data-auto="${o.auto ? 'oui' : 'non'}"
        data-noir="${o.noir ? 'oui' : 'non'}"
        ${taille ? `data-taille="${taille}"
        style="width:${taille}px;height:${taille}px"` : ''}></canvas>`;
    },
  };
})();
