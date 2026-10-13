/*
 * L'arrangement libre du dex — comme des icônes sur un bureau.
 *
 * On entre en mode arrangement par un appui long sur une trouvaille, ou par le
 * bouton « Ranger » du titre. La section « Trouvées » devient alors une
 * surface où l'on déplace, agrandit et retaille les vignettes ; le reste du
 * catalogue garde sa grille paginée.
 *
 * **Le geste.** On reste appuyé sur une vignette : elle se soulève. On la
 * déplace, l'ombre qu'elle laisse dans la grille glisse vers la case où elle
 * tombera, les voisines s'écartent. On lâche : elle se pose. À la souris, pas
 * d'attente — on tire, c'est tout. Un simple appui règle la vignette : taille,
 * forme, masquage. La poignée en bas à droite d'une vignette réglée se tire
 * pour la retailler en cellules.
 *
 * **Pourquoi seulement les trouvailles.** Le catalogue compte 977 416 cases :
 * les charger toutes ferait 396 Mo. Une disposition libre ne peut pas paginer
 * — déplacer une vignette suppose de savoir où sont les autres. Les espèces
 * découvertes, elles, tiennent en mémoire : mille font 415 Ko. Et de toute
 * façon, on n'arrange pas ce qu'on n'a pas trouvé.
 *
 * **En cellules, jamais en pixels.** La grille logique fait toujours cinq
 * colonnes ; c'est la taille des cellules qui suit l'écran. Un arrangement fait
 * sur un téléphone se retrouve identique sur une tablette. Les vignettes sont
 * posées en absolu par des variables CSS (`--c --r --l --h`) : la feuille de
 * style en déduit la position, et le code ici retrouve la cellule sous le doigt
 * par la même arithmétique — un seul calcul, deux lectures.
 *
 * **On ne stocke que les exceptions.** Une case sans position suit la
 * disposition automatique et se pose à la suite. Une nouvelle découverte ne
 * défait donc jamais un arrangement.
 *
 * **Ce que la version précédente faisait mal, et qu'on ne refait pas :**
 *   - elle n'écoutait que `touchstart` : à la souris, rien ne bougeait ;
 *   - elle retranchait 16 px de marge que la grille n'avait pas, d'où une
 *     colonne de décalage entre le doigt et la case visée ;
 *   - elle redessinait toute la page à chaque cellule traversée : trois cents
 *     images redemandées, le geste saccadait ;
 *   - elle laissait `touch-action: pan-y` au navigateur, qui prenait le
 *     défilement au premier pixel vertical et annulait le geste.
 */
const Disposition = (() => {
  'use strict';

  const CACHE = 'biodex_disposition';

  const FORMES = {
    arrondi:  t('Arrondi'),
    carre:    t('Carré'),
    rond:     t('Rond'),
    hexagone: t('Hexagone'),
    losange:  t('Losange'),
    goutte:   t('Goutte'),
  };

  /* La géométrie, en pixels, telle que `style.css` la pose sur `.grille-libre`.
   * Les deux doivent dire la même chose : ce sont les mêmes nombres. */
  const GOUTTIERE = 8;   // entre deux colonnes
  const ESPACE = 10;     // entre deux rangées
  const NOM = 30;        // la ligne du nom sous la vignette

  /* Le temps d'appui avant que la vignette se soulève, au doigt. Assez court
   * pour ne pas sembler planté, assez long pour qu'un début de défilement —
   * qui bouge dès les premières dizaines de millisecondes — passe devant. */
  const DELAI_LEVEE = 200;
  const SEUIL_SCROLL = 10;   // au-delà, avant la levée : c'est un défilement
  const SEUIL_SOURIS = 5;    // au-delà, à la souris : c'est un glissement

  const colonnes = () => etat.disposition?.colonnes || 5;
  const tailleMax = () => etat.disposition?.taille_max || 3;

  /* L'état du mode arrangement. `null` quand on n'y est pas — c'est ce qui
   * décide de tout le reste de l'affichage. */
  let mode = null;

  /* La pile des états précédents, pour défaire. On empile un instantané
   * **avant** chaque geste plutôt que de décrire le geste : défaire devient une
   * affectation, et trente positions pèsent deux kilo-octets. */
  const HISTOIRE = [];
  const PROFONDEUR = 40;

  const copie = (x) => JSON.parse(JSON.stringify(x));

  function retiens() {
    HISTOIRE.push({ places: copie(mode.places), vides: copie(mode.vides) });
    if (HISTOIRE.length > PROFONDEUR) HISTOIRE.shift();
    mode.sale = true;
  }

  function defait() {
    if (!mode || !HISTOIRE.length) return;
    const avant = HISTOIRE.pop();
    mode.places = avant.places;
    mode.vides = avant.vides;
    mode.sale = HISTOIRE.length > 0;
    // La sélection peut désigner une case vide qui n'existe plus.
    if (typeof mode.choisie === 'string'
        && !mode.vides[Number(mode.choisie.slice(1))]) mode.choisie = null;
    touche();
  }

  /* ── charger et enregistrer ─────────────────────────────────────────────
   *
   * L'arrangement vit sur le serveur : c'est le seul moyen qu'il suive d'un
   * appareil à l'autre, entre l'application Android et le site sur iPhone. Le
   * cache local sert uniquement à dessiner tout de suite, sans attendre
   * l'aller-retour — le serveur reste la référence et corrige au retour.
   */
  function depuisLeCache() {
    try { return JSON.parse(localStorage.getItem(CACHE) || 'null'); }
    catch (_) { return null; }
  }

  function versLeCache(d) {
    try { localStorage.setItem(CACHE, JSON.stringify(d)); } catch (_) {}
  }

  async function charge() {
    const local = depuisLeCache();
    if (local) etat.disposition = local;
    try {
      const d = await appel('/dex/disposition');
      etat.disposition = d;
      versLeCache(d);
      dessine();
    } catch (_) {
      // Hors ligne : le cache fait le travail, et l'arrangement reste modifiable.
    }
  }

  async function enregistre() {
    if (!mode || mode.envoie) return;
    const cases = Object.entries(mode.places).map(([id, p]) => ({
      case_id: Number(id),
      colonne: p.colonne, rangee: p.rangee,
      largeur: p.largeur, hauteur: p.hauteur,
      forme: p.forme || 'arrondi', masque: !!p.masque,
    }));
    // Le dex ne charge que ses trois cents premières trouvailles. Enregistrer
    // en remplaçant tout effacerait la position de celles qui n'étaient pas à
    // l'écran — une perte silencieuse, et la pire qui soit. `partiel` dit au
    // serveur de ne toucher qu'aux cases envoyées.
    const partiel = etat.trouvees.length >= 300;
    mode.envoie = true;
    rafraichitBarre();
    try {
      await appel('/dex/disposition',
                  { method: 'PUT', body: { cases, vides: mode.vides, partiel } });
      etat.disposition = {
        ...etat.disposition,
        places: { ...(etat.disposition?.places || {}), ...copie(mode.places) },
        vides: copie(mode.vides),
      };
      versLeCache(etat.disposition);
      HISTOIRE.length = 0;
      mode = null;
      signale(t('Disposition enregistrée.'));
      dessine();
    } catch (e) {
      mode.envoie = false;
      rafraichitBarre();
      signale(e.message, true);
    }
  }

  async function parDefaut() {
    if (!confirm(t('Revenir à la disposition automatique ?\\n\\n')
                 + t('Ton arrangement sera perdu.'))) return;
    try {
      await appel('/dex/disposition', { method: 'DELETE' });
      etat.disposition = { ...etat.disposition, places: {}, vides: [] };
      versLeCache(etat.disposition);
      HISTOIRE.length = 0;
      if (mode) {
        // Les cases reprennent leur place automatique : on refige tout, à
        // partir d'un arrangement vide.
        mode.places = {}; mode.vides = []; mode.choisie = null; mode.sale = false;
        mode.places = figees(etat.trouvees);
      }
      signale(t('Disposition remise à zéro.'));
      dessine();
    } catch (e) { signale(e.message, true); }
  }

  /* Quitter, c'est renoncer à ce qu'on n'a pas enregistré : on le dit. */
  function quitte() {
    if (!mode) return;
    if (mode.sale && !confirm(t('Quitter sans enregistrer ?\\n\\n')
                              + t('Les changements seront perdus.'))) return;
    HISTOIRE.length = 0;
    mode = null;
    dessine();
  }

  /* ── le placement ───────────────────────────────────────────────────────
   *
   * Les cases sans position sont posées à la suite, dans le premier trou assez
   * grand. C'est ce qui fait qu'une nouvelle découverte apparaît sans défaire
   * l'arrangement, et qu'un dex jamais arrangé ressemble à une grille ordinaire.
   */
  function dispose(cases) {
    const n = colonnes();
    const places = mode ? mode.places : (etat.disposition?.places || {});
    const vides = mode ? mode.vides : (etat.disposition?.vides || []);
    const occupe = new Set();
    const marque = (c, r, l, h) => {
      for (let y = r; y < r + h; y++) {
        for (let x = c; x < c + l; x++) occupe.add(`${x},${y}`);
      }
    };
    // Les cases vides occupent la place : une nouvelle trouvaille ne doit pas
    // tomber dedans, c'est tout l'intérêt d'un trou posé à la main.
    for (const v of vides) marque(v.colonne, v.rangee, v.largeur, v.hauteur);

    const sortie = [];
    const libres = [];
    for (const cas of cases) {
      const p = places[cas.id];
      // Masquée hors du mode arrangement : elle sort de la grille. Dedans, on
      // la garde en transparence — sinon on ne pourrait plus la démasquer.
      if (p?.masque && !mode) continue;
      if (p) {
        sortie.push({ cas, ...p });
        if (!p.masque) marque(p.colonne, p.rangee, p.largeur, p.hauteur);
      } else libres.push(cas);
    }

    let c = 0;
    let r = 0;
    for (const cas of libres) {
      while (occupe.has(`${c},${r}`)) {
        c += 1;
        if (c >= n) { c = 0; r += 1; }
      }
      // Pas de forme : une case qu'on n'a jamais réglée doit garder
      // exactement l'apparence qu'elle avait avant que ce mode existe.
      sortie.push({ cas, colonne: c, rangee: r, largeur: 1, hauteur: 1,
                    forme: null, masque: false });
      marque(c, r, 1, 1);
    }
    return sortie;
  }

  /* Combien de rangées la grille occupe. */
  function rangs(places, vides) {
    let n = 1;
    for (const p of places) if (!p.masque || mode) n = Math.max(n, p.rangee + p.hauteur);
    for (const v of vides) n = Math.max(n, v.rangee + v.hauteur);
    return n;
  }

  /* Fige la disposition courante, positions calculées d'office comprises.
   * Sans ça, déplacer une vignette recalculerait la place de toutes les autres
   * et l'écran sauterait à chaque geste. */
  function figees(cases) {
    const places = {};
    for (const p of dispose(cases)) {
      places[p.cas.id] = { colonne: p.colonne, rangee: p.rangee,
                           largeur: p.largeur, hauteur: p.hauteur,
                           forme: p.forme || null, masque: !!p.masque };
    }
    return places;
  }

  /* ── le mode arrangement ────────────────────────────────────────────────*/

  function entre(cases) {
    if (mode) return;
    // On fige **avant** d'ouvrir le mode : `dispose()` lit l'arrangement
    // enregistré tant que `mode` est nul, et celui en cours ensuite.
    const places = figees(cases);
    mode = { places, vides: copie(etat.disposition?.vides || []),
             choisie: null, sale: false, envoie: false };
    HISTOIRE.length = 0;
    navigator.vibrate?.(12);
    dessine();
    // La barre d'arrangement remplace le titre : on la montre.
    document.querySelector('.barre-arrangement')
      ?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  const actif = () => mode !== null;
  const choisie = () => mode?.choisie ?? null;

  /* Les cases vides sont désignées par « vN », les vignettes par leur
   * identifiant d'espèce : les deux ne se confondent jamais. */
  const estVide = (cle) => typeof cle === 'string';
  const rangVide = (cle) => Number(cle.slice(1));
  const placeDe = (cle) => estVide(cle) ? mode?.vides[rangVide(cle)] : mode?.places[cle];

  function selectionne(cle) {
    if (!mode) return;
    mode.choisie = (cle === null || mode.choisie === cle) ? null : cle;
    touche();
  }

  /* Deux rectangles de la grille se recouvrent-ils ? */
  function croise(a, b) {
    return a.colonne < b.colonne + b.largeur
        && b.colonne < a.colonne + a.largeur
        && a.rangee < b.rangee + b.hauteur
        && b.rangee < a.rangee + a.hauteur;
  }

  /* Tout ce qui occupe la grille, cases vides comprises, avec sa clé. */
  function tout() {
    const l = Object.entries(mode.places)
      .filter(([, p]) => !p.masque)
      .map(([id, p]) => [Number(id), p]);
    mode.vides.forEach((v, i) => l.push([`v${i}`, v]));
    return l;
  }

  /* Poser une vignette à un endroit précis.
   *
   * Ce qu'on fait de ce qui s'y trouve déjà :
   *   une seule vignette, de même gabarit → on échange les deux places. C'est
   *       ce qu'on attend en déposant une icône sur une autre, et c'est
   *       réversible d'un seul geste.
   *   tout le reste → on repousse vers le bas ce qui gêne, ligne par ligne. Un
   *       échange entre tailles différentes laisserait des trous imprévisibles.
   * Une case vide, elle, a le droit de recouvrir : c'est un trou, et l'y
   * interdire empêcherait de la sortir d'un endroit encombré. */
  function pose(cle, colonne, rangee) {
    const p = placeDe(cle);
    if (!p) return false;
    const c = Math.max(0, Math.min(colonnes() - p.largeur, colonne));
    const r = Math.max(0, rangee);
    if (p.colonne === c && p.rangee === r) return false;

    const vise = { colonne: c, rangee: r, largeur: p.largeur, hauteur: p.hauteur };
    const genants = tout().filter(([k, q]) => k !== cle && croise(vise, q));

    retiens();
    if (!estVide(cle) && genants.length === 1 && !estVide(genants[0][0])) {
      const autre = genants[0][1];
      if (autre.largeur === p.largeur && autre.hauteur === p.hauteur) {
        autre.colonne = p.colonne;
        autre.rangee = p.rangee;
        p.colonne = c;
        p.rangee = r;
        touche();
        return true;
      }
    }
    p.colonne = c;
    p.rangee = r;
    if (!estVide(cle)) demele(cle);
    touche();
    return true;
  }

  function bouge(cle, dc, dr) {
    const p = placeDe(cle);
    if (!p) return;
    pose(cle, p.colonne + dc, p.rangee + dr);
  }

  function taille(cle, l, h) {
    const p = placeDe(cle);
    if (!p) return;
    const max = tailleMax();
    l = Math.max(1, Math.min(max, l));
    h = Math.max(1, Math.min(max, h));
    if (p.largeur === l && p.hauteur === h) return;
    retiens();
    p.largeur = l;
    p.hauteur = h;
    // Une vignette élargie ne doit pas sortir de la grille par la droite.
    p.colonne = Math.min(p.colonne, colonnes() - p.largeur);
    // Une vignette agrandie recouvre ses voisines : on écarte ce qu'elle mord.
    if (!estVide(cle)) demele(cle);
    touche();
  }

  function changeForme(cle, forme) {
    const p = placeDe(cle);
    if (!p || estVide(cle)) return;
    // `null` remet l'apparence d'origine — ce n'est pas une forme de plus, c'est
    // l'absence de réglage.
    if (forme !== null && !FORMES[forme]) return;
    retiens();
    p.forme = forme;
    touche();
  }

  /* Défaire **toutes** les superpositions, pas seulement celles de la vignette
   * qu'on vient de poser : une vignette repoussée retombe sur une autre, qui
   * retombe sur une troisième. On relit donc toutes les paires après chaque
   * passe. `ancree` est celle qu'on vient de poser : la seule qui ne bouge pas. */
  function demele(ancree) {
    for (let passe = 0; passe < 200; passe++) {
      let bouge = false;
      const liste = tout().sort((a, b) =>
        (a[1].rangee - b[1].rangee) || (a[1].colonne - b[1].colonne));
      for (let i = 0; i < liste.length; i++) {
        for (let j = i + 1; j < liste.length; j++) {
          const [ka, a] = liste[i];
          const [kb, b] = liste[j];
          if (!croise(a, b)) continue;
          // On descend celle qui est déjà la plus basse — ou la seconde à
          // égalité. Descendre la plus haute remonterait la pile au lieu de
          // l'étaler.
          const victime = ka === ancree ? b : kb === ancree ? a : b;
          const fixe = victime === b ? a : b;
          victime.rangee = fixe.rangee + fixe.hauteur;
          bouge = true;
        }
      }
      if (!bouge) return;
    }
    // Garde-fou : une grille finie se démêle toujours, mais des données abîmées
    // ne doivent pas bloquer la page.
  }

  /* Masquer une vignette : elle reste au dex et compte toujours, elle
   * n'apparaît simplement plus dans la grille. */
  function basculeMasque(id) {
    if (!mode?.places[id]) return;
    retiens();
    mode.places[id].masque = !mode.places[id].masque;
    touche();
  }

  /* Une case vide : un trou qu'on pose soi-même, pour aérer ou caler une ligne.
   * Elle se pose sur la première cellule libre : posée au hasard, elle
   * recouvrirait une vignette et il faudrait la chercher pour la déplacer. */
  function ajouteVide() {
    if (!mode) return;
    retiens();
    const n = colonnes();
    const pris = tout().map(([, p]) => p);
    let c = 0;
    let r = 0;
    for (let i = 0; i < 6000; i++) {
      const essai = { colonne: c, rangee: r, largeur: 1, hauteur: 1 };
      if (!pris.some((x) => croise(essai, x))) break;
      c += 1;
      if (c >= n) { c = 0; r += 1; }
    }
    mode.vides.push({ colonne: c, rangee: r, largeur: 1, hauteur: 1 });
    mode.choisie = `v${mode.vides.length - 1}`;
    dessine();
    document.querySelector('.case-vide.active')
      ?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  function retireVide(i) {
    if (!mode?.vides[i]) return;
    retiens();
    mode.vides.splice(i, 1);
    mode.choisie = null;
    dessine();
  }

  /* ── redessiner au plus juste ───────────────────────────────────────────
   *
   * Un déplacement ne change que des positions : les vignettes sont déjà à
   * l'écran, avec leurs images décodées. `dessine()` les détruirait toutes pour
   * les refaire à l'identique — c'est ce qui rendait le glissement poussif. On
   * retouche donc le DOM en place : les variables CSS de position, les classes,
   * le panneau et la barre. Et on retombe sur le rendu complet dès que la
   * composition a changé — une case apparue, une case vide ajoutée.
   */
  // Son clic ne remonte pas à la vignette : un appui sans tirer sur la poignée
  // ne doit pas désélectionner ce qu'on vient de régler.
  const POIGNEE = '<span class="poignee-taille" data-poignee aria-hidden="true"'
                + ` ${t('onclick="event.stopPropagation()">')}</span>`;

  function rafraichit() {
    const grille = document.querySelector('.grille-libre.arrange');
    if (!grille || !mode) return false;
    const places = dispose(etat.trouvees);
    const vides = mode.vides;
    const elVides = grille.querySelectorAll('.case-vide');
    if (elVides.length !== vides.length) return false;

    const posePosition = (el, p) => {
      el.style.setProperty('--c', p.colonne);
      el.style.setProperty('--r', p.rangee);
      el.style.setProperty('--l', p.largeur);
      el.style.setProperty('--h', p.hauteur);
    };
    const poseActive = (el, active) => {
      el.classList.toggle('active', active);
      const poignee = el.querySelector('[data-poignee]');
      if (active && !poignee) el.insertAdjacentHTML('beforeend', POIGNEE);
      if (!active && poignee) poignee.remove();
    };

    for (const p of places) {
      const el = grille.querySelector(`[data-case="${p.cas.id}"]`);
      if (!el) return false;
      posePosition(el, p);
      el.classList.toggle('masquee', !!p.masque);
      for (const c of [...el.classList]) if (c.startsWith('f-')) el.classList.remove(c);
      if (p.forme) el.classList.add(`f-${p.forme}`);
      poseActive(el, mode.choisie === p.cas.id);
    }
    elVides.forEach((el, i) => {
      posePosition(el, vides[i]);
      poseActive(el, mode.choisie === `v${i}`);
    });
    grille.style.setProperty('--rangs', rangs(places, vides) + 2);
    return true;
  }

  function rafraichitPanneau() {
    if (!mode) return;
    const el = document.querySelector('.panneau-vignette');
    const html = mode.choisie !== null ? panneauVignette(mode.choisie) : '';
    if (el && html) el.outerHTML = html;
    else if (el) el.remove();
    else if (html) document.querySelector('.grille-libre')?.insertAdjacentHTML('afterend', html);
  }

  function rafraichitBarre() {
    if (!mode) return;
    const el = document.querySelector('.barre-arrangement');
    if (el) el.outerHTML = barreArrangement();
  }

  function touche() {
    if (!rafraichit()) { dessine(); return; }
    rafraichitPanneau();
    rafraichitBarre();
  }

  /* ── les gestes ─────────────────────────────────────────────────────────
   *
   * Posés une fois, sur le document : déplacer une vignette peut redessiner la
   * grille, et des écouteurs posés sur elle mourraient avec elle au premier
   * pas. Sur le document, ils survivent à tous les rendus.
   *
   * Tout passe par les Pointer Events — doigt, souris et stylet d'un même
   * code. Le seul écouteur tactile qui reste est `touchmove`, parce que lui
   * seul peut encore interdire le défilement une fois la vignette soulevée.
   */
  let saisie = null;   // le geste en cours, ou null

  function geometrie() {
    const g = document.querySelector('.grille-libre.arrange');
    if (!g) return null;
    const r = g.getBoundingClientRect();
    const n = colonnes();
    const cellule = (r.width - (n - 1) * GOUTTIERE) / n;
    return { g, r, n, cellule, pas: cellule + GOUTTIERE, rangee: cellule + NOM + ESPACE };
  }

  function debute(e) {
    if (!mode || saisie || (e.pointerType === 'mouse' && e.button !== 0)) return;
    const poignee = e.target.closest('.grille-libre.arrange [data-poignee]');
    const tuile = e.target.closest('.grille-libre.arrange [data-case], .grille-libre.arrange [data-vide]');
    if (!tuile) return;
    const cle = tuile.dataset.case ? Number(tuile.dataset.case) : `v${tuile.dataset.vide}`;
    const rect = tuile.getBoundingClientRect();
    saisie = { cle, tuile, rect, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY,
               type: e.pointerType, leve: false, retaille: !!poignee, bouge: false,
               derniere: null, minuteur: null, fantome: null, boucle: 0 };
    if (saisie.retaille) {
      // La poignée n'existe que sur la vignette réglée : l'intention est claire,
      // on retaille tout de suite, au doigt comme à la souris.
      e.preventDefault();
      document.body.classList.add('retaille');
      return;
    }
    if (e.pointerType === 'mouse') return;   // la souris se soulève au mouvement
    saisie.minuteur = setTimeout(() => { if (saisie && !saisie.leve) leve(); }, DELAI_LEVEE);
  }

  /* La vignette se soulève : une copie suit le doigt, l'originale reste en
   * creux dans la grille et devient l'ombre de l'endroit où elle tombera. */
  function leve() {
    const s = saisie;
    clearTimeout(s.minuteur);
    s.leve = true;
    navigator.vibrate?.(10);
    const f = s.tuile.cloneNode(true);
    f.classList.remove('active', 'deplacee');
    f.classList.add('fantome');
    f.querySelector('[data-poignee]')?.remove();
    f.removeAttribute('onclick');
    f.style.cssText = `left:${s.rect.left}px;top:${s.rect.top}px;`
                    + `${t('width:{0}px;height:{1}px', [s.rect.width, s.rect.height])}`;
    document.body.appendChild(f);
    s.fantome = f;
    s.tuile.classList.add('deplacee');
    document.body.classList.add('glisse');
    suit();
    defile();
  }

  function suit() {
    const s = saisie;
    if (!s?.fantome) return;
    s.fantome.style.transform =
      `translate3d(${s.x - s.x0}px, ${s.y - s.y0}px, 0) scale(1.06)`;
  }

  /* La cellule où tombera la vignette : celle sous le coin haut-gauche de la
   * copie qu'on tient, arrondi au plus proche. Viser avec le coin et non avec le
   * doigt, c'est ce qui fait qu'une vignette large se pose là où on la voit. */
  function vise() {
    const s = saisie;
    const geo = geometrie();
    if (!s || !geo) return;
    const gx = s.rect.left + (s.x - s.x0) - geo.r.left;
    const gy = s.rect.top + (s.y - s.y0) - geo.r.top;
    const colonne = Math.round(gx / geo.pas);
    const rangee = Math.round(gy / geo.rangee);
    const cle = `${colonne},${rangee}`;
    if (s.derniere === cle) return;
    s.derniere = cle;
    if (pose(s.cle, colonne, rangee)) s.bouge = true;
    // La grille a pu être recréée entre-temps : on reprend la tuile.
    const neuve = document.querySelector(estVide(s.cle)
      ? `.grille-libre.arrange [data-vide="${rangVide(s.cle)}"]`
      : `.grille-libre.arrange [data-case="${s.cle}"]`);
    if (neuve && neuve !== s.tuile) { s.tuile = neuve; }
    s.tuile.classList.add('deplacee');
  }

  /* La poignée tirée : autant de cellules que le doigt en couvre depuis le
   * coin haut-gauche de la vignette. */
  function retaille() {
    const s = saisie;
    const geo = geometrie();
    if (!s || !geo) return;
    const l = Math.floor((s.x - s.rect.left + GOUTTIERE / 2) / geo.pas) + 1;
    const h = Math.floor((s.y - s.rect.top + ESPACE / 2) / geo.rangee) + 1;
    const cle = `${l}x${h}`;
    if (s.derniere === cle) return;
    s.derniere = cle;
    taille(s.cle, l, h);
  }

  /* Approcher du bord de l'écran fait défiler la page : la grille peut faire
   * dix écrans, et on doit pouvoir porter une vignette du haut en bas. */
  function defile() {
    const s = saisie;
    if (!s?.leve) return;
    const haut = (document.querySelector('.barre-arrangement')?.getBoundingClientRect().bottom || 0) + 56;
    const bas = innerHeight - 64 - 72;
    let v = 0;
    if (s.y < haut) v = -Math.min(24, (haut - s.y) / 3);
    else if (s.y > bas) v = Math.min(24, (s.y - bas) / 3);
    if (v) { scrollBy(0, v); vise(); }
    s.boucle = requestAnimationFrame(defile);
  }

  function avance(e) {
    const s = saisie;
    if (!s) return;
    s.x = e.clientX;
    s.y = e.clientY;
    if (s.retaille) { retaille(); return; }
    const d = Math.hypot(s.x - s.x0, s.y - s.y0);
    if (!s.leve) {
      if (s.type === 'mouse') { if (d > SEUIL_SOURIS) leve(); else return; }
      else if (d > SEUIL_SCROLL) { abandonne(); return; }   // c'est un défilement
      else return;
    }
    suit();
    vise();
  }

  function abandonne() {
    const s = saisie;
    if (!s) return;
    clearTimeout(s.minuteur);
    cancelAnimationFrame(s.boucle);
    s.fantome?.remove();
    s.tuile.classList.remove('deplacee');
    document.body.classList.remove('glisse', 'retaille');
    saisie = null;
  }

  function termine() {
    const s = saisie;
    if (!s) return;
    clearTimeout(s.minuteur);
    cancelAnimationFrame(s.boucle);
    document.body.classList.remove('glisse', 'retaille');
    if (s.leve && s.fantome) {
      // La copie rejoint sa case d'un glissement court, puis s'efface : on voit
      // la vignette se poser, pas apparaître.
      const f = s.fantome;
      const tuile = s.tuile;
      const cible = tuile.getBoundingClientRect();
      f.classList.add('pose');
      f.style.transform = `translate3d(${cible.left - s.rect.left}px, ${cible.top - s.rect.top}px, 0) scale(1)`;
      setTimeout(() => { f.remove(); tuile.classList.remove('deplacee'); }, 170);
      // Un glissement n'est pas un appui : le clic que la souris synthétise
      // ensuite ne doit pas ouvrir le panneau de réglage. Au doigt, un
      // `touchmove` empêché n'engendre aucun clic — armer le garde-fou
      // avalerait le tap suivant pendant sept cents millisecondes.
      if (s.bouge && s.type === 'mouse') appuiLongA = performance.now();
    }
    if (s.retaille && s.type === 'mouse') appuiLongA = performance.now();
    saisie = null;
  }

  function poseGestes() {
    if (document.body.dataset.gestesDex) return;
    document.body.dataset.gestesDex = 'oui';
    addEventListener('pointerdown', debute, { passive: false });
    addEventListener('pointermove', avance, { passive: true });
    addEventListener('pointerup', termine);
    addEventListener('pointercancel', abandonne);
    // Une fois la vignette soulevée, le doigt déplace la vignette et plus la
    // page. `touchmove` est le seul événement qui puisse encore le dire au
    // navigateur — et seulement s'il n'a pas déjà commencé à défiler, d'où
    // l'attente immobile avant la levée.
    addEventListener('touchmove', (e) => {
      if (saisie && (saisie.leve || saisie.retaille)) e.preventDefault();
    }, { passive: false });
    // Ni menu contextuel sur appui long, ni glisser-déposer natif des images :
    // les deux volent le geste.
    addEventListener('contextmenu', (e) => {
      if (mode && e.target.closest('.grille-libre.arrange')) e.preventDefault();
    });
    addEventListener('dragstart', (e) => {
      if (mode && e.target.closest('.grille-libre.arrange')) e.preventDefault();
    });
    // Au clavier : les flèches déplacent la vignette réglée, Échap la relâche.
    addEventListener('keydown', (e) => {
      // La cible peut être `window` lui-même, qui n'a pas de `matches`.
      if (!mode || mode.choisie === null || e.target?.matches?.('input, textarea')) return;
      const pas = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] }[e.key];
      if (pas) { e.preventDefault(); bouge(mode.choisie, ...pas); }
      else if (e.key === 'Escape') selectionne(null);
    });
  }

  return {
    FORMES, GOUTTIERE, ESPACE, NOM,
    charge, dispose, rangs, entre, quitte, enregistre, parDefaut, defait,
    actif, choisie, selectionne, bouge, taille, changeForme, pose,
    basculeMasque, ajouteVide, retireVide, poseGestes,
    vides: () => mode?.vides || etat.disposition?.vides || [],
    places: () => mode?.places || etat.disposition?.places || {},
    peutDefaire: () => HISTOIRE.length > 0,
    modifie: () => !!mode?.sale,
    envoie: () => !!mode?.envoie,
    estVide, rangVide,
  };
})();
