/* Le Biodex en navigateur — l'application entière.
 *
 * Pas de cadre, pas d'outil de compilation : des fonctions qui rendent du
 * HTML, et un état global. À cette taille une dépendance coûterait plus
 * cher qu'elle ne rapporte, et il n'y a rien ici qu'un navigateur d'iPhone
 * ne sache faire nativement.
 *
 * **Tout passe par l'API**, jamais par la base : l'authentification, les
 * règles du dex, le calcul des points et la validation des photos vivent sur
 * le serveur. Cette page n'est qu'un affichage. */

/* Où vit le site, vu du navigateur.
 *
 * À la racine d'un domaine, c'est « / ». Derrière un proxy inverse qui le
 * monte sous « /web/ », c'est « /web/ » — et tout ce qui suit doit en tenir
 * compte, sinon la page demande « /api/dex » au serveur principal, qui n'a
 * pas de route « /api ».
 *
 * On le déduit de l'adresse courante plutôt que de le configurer : le site
 * n'a pas de routage interne, donc le chemin de la page *est* sa racine. */
const RACINE = location.pathname.replace(/[^/]*$/, '');
const CASES_ENTIERES = 'biodex_cases_entieres';
const API = `${RACINE}api`;
const JETON = 'biodex_jeton';

/* ─────────────────────────────── le réseau ─────────────────────────────── */

function jeton() { return localStorage.getItem(JETON) || biscuit(); }

/* Le jeton tel que le navigateur nous le rend. Safari purge le stockage local
 * d'un site qu'on n'a pas ouvert depuis sept jours, mais garde les biscuits
 * d'une application ajoutée à l'écran d'accueil : sans ce repli, l'app se
 * déconnectait toute seule au bout d'une semaine. */
function biscuit() {
  const m = document.cookie.match(new RegExp(`(?:^|; )${JETON}=([^;]*)`));
  return m ? decodeURIComponent(m[1]) : null;
}

/* Le jeton vit à deux endroits, et pas par négligence.
 *
 * `localStorage` sert aux appels `fetch`, qui posent leur en-tête
 * `Authorization` eux-mêmes. Mais une balise `<img>` n'a pas cette liberté :
 * avatars, vignettes et badges partaient donc sans jeton et revenaient en 401.
 * Le biscuit comble ce trou — il accompagne automatiquement toute requête de
 * même origine, images comprises, et le relais le retraduit en en-tête.
 *
 * Le mettre dans l'adresse aurait été plus court, et l'aurait semé dans les
 * journaux du proxy, l'historique du navigateur et l'en-tête `Referer`. */
function poseBiscuit(valeur) {
  const sur = location.protocol === 'https:' ? '; Secure' : '';
  document.cookie = valeur
    ? `${JETON}=${encodeURIComponent(valeur)}; path=${RACINE}; max-age=31536000; SameSite=Lax${sur}`
    : `${JETON}=; path=${RACINE}; max-age=0; SameSite=Lax${sur}`;
}

function garde(valeur) {
  localStorage.setItem(JETON, valeur);
  poseBiscuit(valeur);
}

function oublie() {
  localStorage.removeItem(JETON);
  poseBiscuit(null);
}

/* Les routes où un 401 veut dire « mauvais identifiants », pas « session
 * expirée ». La distinction n'est pas cosmétique : sans elle, quelqu'un qui
 * se trompe de mot de passe voit son jeton effacé et un message faux. */
const SANS_SESSION = ['/connexion', '/inscription'];

/* Le message d'erreur du serveur, quelle que soit sa forme.
 *
 * FastAPI renvoie `detail` en texte pour une erreur métier, mais en liste
 * d'objets pour une erreur de validation. Passer l'objet brut à `Error()`
 * donnait « [object Object] », qui n'apprend rien à personne. */
function messageErreur(corps, code) {
  const d = corps?.detail;
  if (typeof d === 'string') return d;
  if (Array.isArray(d)) {
    return d.map((e) => {
      const champ = Array.isArray(e.loc) ? e.loc[e.loc.length - 1] : null;
      return champ ? `${champ} : ${e.msg}` : e.msg;
    }).join(' · ');
  }
  if (d && typeof d === 'object') return JSON.stringify(d);
  return `${t('Erreur {0}', [code])}`;
}

async function appel(chemin, options = {}) {
  const entetes = { ...(options.headers || {}) };
  const j = jeton();
  if (j) entetes.Authorization = `Bearer ${j}`;
  entetes['Accept-Language'] = langueCourante();
  if (options.body && !(options.body instanceof FormData)) {
    entetes['Content-Type'] = 'application/json';
    options.body = JSON.stringify(options.body);
  }
  const r = await fetch(`${API}${chemin}`, { ...options, headers: entetes });
  const texte = await r.text();
  let corps = null;
  try { corps = texte ? JSON.parse(texte) : null; } catch (_) { corps = null; }

  if (r.status === 401 && !SANS_SESSION.some((c) => chemin.startsWith(c))) {
    oublie();
    Object.assign(etat, { moi: null, trouvees: [], aTrouver: [], vue: 'connexion',
                          erreur: t('Session expirée, reconnecte-toi.') });
    dessine();
    throw new Error(t('session expirée'));
  }
  if (!r.ok) throw new Error(messageErreur(corps, r.status));
  return corps;
}

/* L'adresse d'une image : le chemin de l'API, sans plus. L'autorisation
 * voyage dans le biscuit, que le navigateur joint de lui-même. */
/* Une vignette Wikimedia à la taille où on l'affiche.
 *
 * Les fiches renvoient du 330 px — quarante kilooctets pour un carré de
 * cinquante-quatre. Douze résultats de recherche faisaient donc un demi-
 * mégaoctet, rechargé à chaque frappe puisque le rendu recrée les balises.
 *
 * Wikimedia met la largeur dans le nom du fichier : `/330px-Nom.jpg`. La
 * réécrire suffit, leur cache fabrique la taille demandée. On ne touche pas
 * aux adresses d'un autre format — mieux vaut une image lourde qu'une image
 * cassée.
 */
function vignetteWiki(url, largeur = 128) {
  if (!url || !url.includes('upload.wikimedia.org')) return url;
  return url.replace(/\/(\d+)px-/, `/${largeur}px-`);
}

function image(chemin) {
  if (!chemin) return '';
  // Les fiches Wikipédia donnent une adresse complète : la préfixer par
  // `/api` la casserait.
  if (chemin.startsWith('http')) return chemin;
  return `${API}${chemin}`;
}

/* ─────────────────────────────── l'état ─────────────────────────────── */

/* L'état neutre des filtres de galerie. Défini à part parce qu'on y revient :
 * « tout effacer » remet exactement ceci, et une valeur oubliée dans une
 * réinitialisation à la main est le genre de bogue qu'on ne voit qu'après
 * l'avoir vécu. */
const FILTRES_VIDES = {
  qui: 'tous',        // tous | moi | amis
  regne: '',          // animal | plante | champignon
  qualite: 0,         // rareté minimale, 0 = indifférent
  favoris: false,
  sansLieu: false,    // deux manques distincts, deux filtres distincts
  sansDate: false,
  lieu: '',
  espece: 0,
  depuis: '', jusqua: '',
  tri: 'recent',
};

const etat = {
  vue: jeton() ? 'dex' : 'connexion',
  moi: null,
  erreur: null,
  info: null,

  // La vitrine : chargée seulement quand on la demande, et le choix du
  // bandeau survit à la fermeture de l'onglet.
  vitrine: null,
  nouvelleEspece: null,
  reglagesNotifs: null,
  orphelines: null,
  aSituerChoisies: new Set(),
  modeCarte: 'plan',
  succes: null,
  succesOuvert: null,
  mesEspeces: null,
  bandeauVitrine: localStorage.getItem('biodex_bandeau_vitrine') === '1',

  // Le dex
  trouvees: [], aTrouver: [], noeuds: [], niveau: 'classe', charge: false,
  mode: 'collection',
  recherche: '', regne: null, tri: 'communes', qualite: null,
  classe: null, ordre: null, famille: null,
  filtresOuverts: false,
  get nbFiltres() { return [this.classe != null, this.qualite != null]
                      .filter(Boolean).length; },
  resume: null,

  // Les autres écrans, chargés à la demande
  fiche: null,
  galerie: [], galerieDepuis: 0, galerieFin: false,
  // Les filtres de la galerie, et les listes qui remplissent leurs menus.
  // `fg` est volontairement court : il apparaît dans une trentaine
  // d'expressions de gabarit où le nom complet noierait le reste.
  fg: { ...FILTRES_VIDES },
  filtresGalerieOuverts: false, reperes: null,
  mesCaptures: [],
  filtrePhotos: 'tout', choisiesPhotos: new Set(), modeTriPhotos: false,
  // Quelle date une notification affiche : celle de sa publication (par
  // défaut) ou celle où la photo a été prise. Les deux sont légitimes et
  // répondent à des questions différentes — « qu'est-ce qui est arrivé
  // récemment » contre « c'était quand, cette sortie » — d'où le réglage
  // plutôt qu'un choix imposé.
  dateNotifsSelon: localStorage.getItem('biodex_date_notifs') || 'publication',
  // La photo choisie mais pas encore envoyée : on la regarde et on règle le
  // règne avant de la confier au moteur.
  preparation: null,
  versionSite: null,
  // Le dex d'un ami ouvert en planche, et mon propre rang dans le cercle.
  dexJoueur: null, classementMoi: null,
  // Les photos d'un paquet de la carte, ouvertes en planche.
  lieu: null,
  amis: [], demandes: [], rechercheAmis: [],
  classement: [],
  notifications: [], nonLues: 0,
  paliers: null,
  carte: [],
  // Les filtres de la carte : qui (null = tout le monde, sinon un ensemble
  // d'identifiants et de 'moi'), nouveautés (null = automatique : oui s'il y
  // en a), règne. Et la vue — centre et zoom — pour la retrouver telle qu'on
  // l'a laissée après avoir ouvert une photo.
  filtreCarte: { qui: 'tous', nouveautes: null, regne: null },
  filtresCarteOuverts: false, rechercheAmiCarte: '',
  carteVue: null,
  enAttente: [], joursAvantPurge: 7,
  aTrancherChoisies: new Set(), aTrancherModeTri: false,
  visionneuse: null, reactions: {}, favori: false,
  suiteVisionneuse: null, situer: null,
  apercu: null, choixEspece: null, illustrations: {},
  identification: null,
  fil: [], chargeFil: false, sortie: null, ongletAmis: 'fil',
  editeur: null,
  choisies: new Set(),
  joueur: null, detailJoueur: null, choixVitrine: null,
  trouvaillesJoueur: null,
  trouvailles: null, ongletClassement: 'joueurs',
  toutLesCredits: false,
  casesEntieres: localStorage.getItem(CASES_ENTIERES) === '1',
  disposition: null,
  captureEnCours: null,
  modeInscription: false,
};

const QUALITES = { 1: t('Commun'), 2: t('Basique'), 3: t('Peu commun'),
                   4: t('Rare'), 5: t('Légendaire') };
const REGNES = [
  { cle: null, nom: t('Tout') },
  { cle: 'animal', nom: t('Animaux') },
  { cle: 'plante', nom: t('Plantes') },
  { cle: 'champignon', nom: t('Champignons') },
  // « Aquatique » n'est pas une valeur de `cases.regne` : le serveur le
  // traduit en filtre taxonomique, puisque les poissons sont rangés sous
  // « animal ». Le filtre marche donc, mais par un autre chemin.
  { cle: 'aquatique', nom: t('Poissons') },
];

function echappe(t) {
  return String(t ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* Une date lisible. Le serveur rend de l'ISO en UTC ; on affiche « il y a
 * deux heures » plutôt qu'un horodatage, qui ne dit rien à personne. */
function quand(iso) {
  if (!iso) return '';
  const d = new Date(iso.endsWith('Z') || iso.includes('+') ? iso : `${iso}Z`);
  const s = (Date.now() - d.getTime()) / 1000;
  if (s < 60) return t('à l\'instant');
  if (s < 3600) return `${t('il y a {0} min', [Math.floor(s / 60)])}`;
  if (s < 86400) return `${t('il y a {0} h', [Math.floor(s / 3600)])}`;
  if (s < 604800) return `${t('il y a {0} j', [Math.floor(s / 86400)])}`;
  return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short' });
}

function signale(texte, erreur = false) {
  etat[erreur ? 'erreur' : 'info'] = t(texte);
  dessine();
  setTimeout(() => { etat.erreur = null; etat.info = null; dessine(); }, 3200);
}

/* ═══════════════════════════════ les écrans ═══════════════════════════════ */

/* ─────────────────────────────── connexion ─────────────────────────────── */

/* L'écran de connexion.
 *
 * C'est la première chose qu'on voit, et il ne montrait rien du jeu : deux
 * champs sur du blanc, comme un intranet. Il porte maintenant une grenouille
 * qui tourne — un modèle qu'on a déjà, aucun fichier de plus — et dit en une
 * ligne ce qu'on vient faire ici.
 *
 * **Aucune adresse mail, et c'est assumé.** Le pseudo et le mot de passe
 * suffisent ; il n'existe donc aucune procédure de récupération. Autant le dire
 * sur l'écran d'inscription plutôt que de le laisser découvrir le jour où on
 * l'oublie.
 */
function vueConnexion() {
  const inscription = etat.modeInscription;
  return `
    <div class="accueil">
      <div class="ciel"></div>
      <div class="accueil-dedans">
        <div class="mascotte">
          ${Media.modele(132, { modele: 'grenouille', auto: true, doigt: true })}
        </div>
        <h1>${t('Biodex')}</h1>
        <p class="accroche">${t('Le dex du vivant.')}<br>${t('Photographie ce que tu croises.')}</p>

        <div class="carte-connexion">
          <div class="segments">
            <button class="${inscription ? '' : 'actif'}"
                    onclick="modeConnexion(false)">${t('Se connecter')}</button>
            <button class="${inscription ? 'actif' : ''}"
                    onclick="modeConnexion(true)">${t('Créer un compte')}</button>
          </div>

          <div class="champ">
            <label for="pseudo">${t('Pseudo')}</label>
            <input id="pseudo" autocomplete="username" autocapitalize="none"
                   placeholder="${t('Comment on t\'appelle')}"
                   onkeydown="if(event.key==='Enter')document.getElementById('mdp').focus()">
          </div>
          <div class="champ">
            <label for="mdp">${t('Mot de passe')}</label>
            <input id="mdp" type="password" placeholder="${t('Au moins 8 caractères')}"
                   autocomplete="${inscription ? 'new-password' : 'current-password'}"
                   onkeydown="if(event.key==='Enter')${
                     inscription ? 'inscrit()' : 'connecte()'}">
          </div>

          ${etat.erreur ? `<div class="erreur">${echappe(etat.erreur)}</div>` : ''}

          <button class="principal" onclick="${inscription ? 'inscrit()' : 'connecte()'}">
            ${inscription ? 'Créer mon compte' : t('Entrer')}</button>

          ${inscription ? `
            <p class="doux avertissement-compte">
              ${t('Pas d\'adresse mail : le pseudo et le mot de passe suffisent. Il n\'existe donc aucun moyen de récupérer un mot de passe perdu — note-le quelque part.')}</p>` : ''}
        </div>

        <p class="doux pied-accueil">
          ${t('Aucune donnée revendue, aucun pistage. Les photos restent entre toi et les amis que tu choisis.')}</p>
      </div>
    </div>`;
}

function modeConnexion(inscription) {
  etat.modeInscription = inscription;
  etat.erreur = null;
  dessine();
}

/* ────────────────────────────────── dex ────────────────────────────────── */

/* Les trois règnes, avec ce qui les distingue à l'écran — mêmes clés, mêmes
 * émojis, mêmes couleurs que `Regne` côté Dart. */
const REGNES_APP = [
  { cle: 'animal', nom: t('Animal'), emoji: '🐾', couleur: '#0EA5A4' },
  { cle: 'plante', nom: t('Plante'), emoji: '🌿', couleur: '#22A34B' },
  { cle: 'champignon', nom: t('Champignon'), emoji: '🍄', couleur: '#E08A0B' },
  // Les poissons ne forment pas un règne : ce sont des animaux, et leur case
  // est une case animale — le poisson-clown existe déjà au dex. Cette carte
  // n'ouvre pas un dex parallèle, elle change de moteur : le catalogue passe
  // de 411 743 espèces à 22 766, ce qui écarte les insectes et les oiseaux qui
  // pouvaient l'emporter sur un reflet derrière une vitre.
  { cle: 'aquatique', nom: t('Aquatique'), emoji: '🐟', couleur: '#2E86DE' },
];
const regneDe = (c) => REGNES_APP.find((r) => r.cle === c) || REGNES_APP[0];

/* Une case de la grille.
 *
 * Le liseré porte la couleur de la qualité, et un halo de la même couleur la
 * fait ressortir : franc sur une trouvaille, à peine visible sur une case
 * vide, plus large à partir de « rare ». C'est ce qui fait qu'une belle prise
 * se repère sans avoir à lire quoi que ce soit.
 *
 * Une case vide ne dit pas ce qu'elle cache : « ??? », et rien d'autre. */
/* L'image d'une case, et comment la poser.
 *
 * Le serveur envoie les deux cadrages et laisse le client trancher : c'est ce
 * qui permet au réglage général de s'appliquer sans aller-retour réseau. Le
 * choix fait sur une case précise l'emporte toujours sur le réglage général —
 * sinon ce ne serait pas un choix. */
function imageDeCase(c) {
  const veutEntier = c.cadrage === 'entier' ? true
    : c.cadrage === 'decoupe' ? false
    : etat.casesEntieres;
  if (!veutEntier && c.decoupe) return { chemin: c.decoupe, detouree: true };
  // Le repli n'est pas symétrique : sans découpe on montre la photo entière,
  // alors que sans photo entière il n'y a rien à montrer du tout.
  return { chemin: c.vignette || c.decoupe,
           detouree: !c.vignette && !!c.decoupe };
}

/* Les trouvailles, disposées comme le joueur les a rangées.
 *
 * Les positions viennent du serveur — c'est ce qui les fait suivre d'un appareil
 * à l'autre — et les cases sans position se posent à la suite. Un dex jamais
 * arrangé ressemble donc exactement à la grille d'avant.
 *
 * Chaque case porte sa position en variables CSS (`--c --r --l --h`) ; la
 * feuille de style en déduit `left/top/width/height`. C'est ce qui permet au
 * mode arrangement de déplacer une vignette en touchant quatre nombres, sans
 * reconstruire la grille. */
function grilleTrouvees() {
  const places = Disposition.dispose(etat.trouvees);
  const vides = Disposition.vides();
  const colonnes = etat.disposition?.colonnes || 5;
  const arrange = Disposition.actif();
  const choisie = Disposition.choisie();
  // En arrangement, deux rangées de marge : on doit pouvoir poser une vignette
  // sous tout ce qui existe.
  const rangs = Disposition.rangs(places, vides) + (arrange ? 2 : 0);

  return `
    <div class="grille-libre ${arrange ? 'arrange' : ''}"
         style="--colonnes:${colonnes};--rangs:${rangs}"
         ${arrange ? 'onclick="if(event.target===this)Disposition.selectionne(null)"' : ''}>
      ${places.map((p) => caseLibre(p, arrange, choisie === p.cas.id)).join('')}
      ${vides.map((v, i) => caseVideHTML(v, i, arrange, choisie === `v${i}`)).join('')}
    </div>
    ${arrange && choisie !== null ? panneauVignette(choisie) : ''}`;
}

const positionCSS = (p) =>
  `--c:${p.colonne};--r:${p.rangee};--l:${p.largeur};--h:${p.hauteur}`;

function caseLibre(p, arrange, active) {
  const c = p.cas;
  const q = c.rarete || 2;
  const img = imageDeCase(c);
  const dedans = img?.chemin
    ? `<img class="${img.detouree ? 'decoupe' : 'pleine'}"
            src="${image(img.chemin)}" alt="" loading="lazy" draggable="false">`
    : silhouetteHTML(c.visuel);
  // En arrangement, toucher sélectionne au lieu d'ouvrir : on est en train de
  // ranger, pas de consulter.
  const action = arrange
    ? `Disposition.selectionne(${c.id})`
    : `ouvreFiche(${c.id})`;
  return `
    <div class="case-dex libre ${p.forme ? `f-${p.forme}` : ''} ${
          active ? 'active' : ''} ${p.masque ? 'masquee' : ''}"
         style="${positionCSS(p)}"
         data-case="${c.id}"
         ${arrange ? '' : `data-appui-long="${c.id}" data-appui-role="arrangement"`}
         onclick="${action}">
      <div class="vignette trouvee q${q}">${dedans}</div>
      <div class="nom">${echappe(c.nom)}</div>
      ${active ? '<span class="poignee-taille" data-poignee aria-hidden="true" onclick="event.stopPropagation()"></span>' : ''}
    </div>`;
}

/* Une case vide : rien hors arrangement, un cadre pointillé dedans. */
function caseVideHTML(v, i, arrange, active) {
  return `
    <div class="case-vide ${arrange ? '' : 'invisible'} ${active ? 'active' : ''}"
         style="${positionCSS(v)}"
         ${arrange ? `data-vide="${i}" onclick="Disposition.selectionne('v${i}')"` : ''}>
      ${arrange ? `<span class="marque-vide">${t('vide')}</span>` : ''}
      ${active ? '<span class="poignee-taille" data-poignee aria-hidden="true" onclick="event.stopPropagation()"></span>' : ''}
    </div>`;
}

/* La barre du mode arrangement. Elle remplace le titre de section : on ne peut
 * pas être en train de ranger et de consulter en même temps, et deux barres
 * superposées mangeraient la moitié de l'écran d'un téléphone.
 *
 * « Enregistrer » vit sur la première ligne, à côté du titre : c'est l'action
 * qui conclut tout le travail, elle ne doit jamais passer à la ligne ni sortir
 * du cadre. Les autres gestes s'alignent dessous. */
function barreArrangement() {
  const tactile = matchMedia('(pointer: coarse)').matches;
  const aide = tactile
    ? t('Reste appuyé sur une vignette et déplace-la. Touche-la pour la régler.')
    : t('Fais glisser une vignette pour la déplacer, clique dessus pour la régler.');
  const envoie = Disposition.envoie();
  return `
    <div class="barre-arrangement">
      <div class="ligne-arrangement">
        <span class="texte">
          <b>${t('Ranger mon dex {0}', [Disposition.modifie()
            ? '<i class="point-sale" title="Modifications non enregistrées"></i>' : ''])}</b>
          <span class="doux">${aide}</span>
        </span>
        <button class="principal" onclick="Disposition.enregistre()" ${envoie ? 'disabled' : ''}>
          ${envoie ? '…' : t('✓ Enregistrer')}</button>
      </div>
      <div class="outils-arrangement">
        <button class="outil-rangement" onclick="Disposition.defait()"
                ${Disposition.peutDefaire() ? '' : 'disabled'} title="${t('Annuler le dernier geste')}">
          <span>↶</span><small>${t('Annuler')}</small></button>
        <button class="outil-rangement" onclick="Disposition.ajouteVide()" title="${t('Poser une case vide')}">
          <span>▢</span><small>${t('Case vide')}</small></button>
        <button class="outil-rangement" onclick="Disposition.parDefaut()" title="${t('Disposition automatique')}">
          <span>⟲</span><small>${t('Par défaut')}</small></button>
        <button class="outil-rangement" onclick="Disposition.quitte()" title="${t('Quitter sans enregistrer')}">
          <span>✕</span><small>${t('Quitter')}</small></button>
      </div>
    </div>`;
}

/* Le panneau de réglage d'une vignette.
 *
 * Chaque réglage montre ce qu'il produit plutôt que de le nommer : une grille de
 * gabarits qu'on désigne du doigt — 1×1, 2×1, 2×2… — plutôt que des boutons qui
 * incrémentent, des formes dessinées plutôt que des mots. L'aperçu en tête dit
 * sur quoi on agit, ce qui manque dès qu'on a deux vignettes voisines.
 *
 * Pas de flèches de position : la vignette se déplace au doigt, à la souris, ou
 * aux flèches du clavier. Les boutons qui faisaient la même chose en moins bien
 * encombraient le panneau sans rien ajouter. */
function panneauVignette(cle) {
  if (Disposition.estVide(cle)) return panneauVide(Disposition.rangVide(cle));

  const p = Disposition.places()[cle];
  if (!p) return '';
  const c = etat.trouvees.find((x) => x.id === cle);
  const max = etat.disposition?.taille_max || 3;
  const img = c ? imageDeCase(c) : null;

  return `
    <div class="panneau-vignette">
      <div class="tete">
        <span class="apercu-reglee ${p.forme ? `f-${p.forme}` : ''}">
          ${img?.chemin ? `<img src="${image(img.chemin)}" alt="">` : ''}
        </span>
        <span class="texte">
          <b>${echappe(c?.nom || 'Vignette')}</b>
          <span class="doux">${p.largeur} × ${p.hauteur}${p.masque ? ' · masquée' : ''}</span>
        </span>
        <button class="outil" onclick="Disposition.selectionne(null)"
                aria-label="${t('Fermer')}">✕</button>
      </div>

      <div class="rangee-reglage">
        <span class="etiquette">${t('Taille')}</span>
        <div class="gabarits">${gabaritsHTML(max, p, (l, h) => `Disposition.taille(${cle}, ${l}, ${h})`)}</div>
      </div>

      <div class="rangee-reglage">
        <span class="etiquette">${t('Forme')}</span>
        <div class="gabarits formes">
          <button class="${!p.forme ? 'actif' : ''}" title="${t('D\'origine')}"
                  onclick="Disposition.changeForme(${cle}, null)">
            <span class="apercu-forme f-defaut"></span></button>
          ${Object.entries(Disposition.FORMES).map(([k, nom]) => `
            <button class="${p.forme === k ? 'actif' : ''}" title="${nom}"
                    onclick="Disposition.changeForme(${cle}, '${k}')">
              <span class="apercu-forme f-${k}"></span></button>`).join('')}
        </div>
      </div>

      <div class="ligne-actions">
        <button class="secondaire" onclick="Disposition.basculeMasque(${cle})">
          ${p.masque ? '👁 Réafficher' : t('🚫 Masquer')}</button>
      </div>
      <p class="doux astuce">${p.masque
        ? t('Masquée, elle reste au dex et compte toujours — elle n\'occupe simplement plus de place.')
        : t('Tire la poignée en bas à droite pour la retailler directement dans la grille.')}</p>
    </div>`;
}

const gabaritsHTML = (max, p, action) => {
  const sortie = [];
  for (let h = 1; h <= max; h++) {
    for (let l = 1; l <= max; l++) {
      sortie.push(`
        <button class="${p.largeur === l && p.hauteur === h ? 'actif' : ''}"
                title="${l} × ${h}" onclick="${action(l, h)}">
          <span style="width:${l * 7}px;height:${h * 7}px"></span>
        </button>`);
    }
  }
  return sortie.join('');
};

/* Une case vide : moins de réglages, parce qu'il y a moins à régler. */
function panneauVide(i) {
  const v = Disposition.vides()[i];
  if (!v) return '';
  const max = etat.disposition?.taille_max || 3;
  return `
    <div class="panneau-vignette">
      <div class="tete">
        <span class="apercu-reglee vide"></span>
        <span class="texte"><b>${t('Case vide')}</b>
          <span class="doux">${t('{0} × {1} · rien ne s\'y affiche', [v.largeur, v.hauteur])}</span></span>
        <button class="outil" onclick="Disposition.selectionne(null)"
                aria-label="${t('Fermer')}">✕</button>
      </div>
      <div class="rangee-reglage">
        <span class="etiquette">${t('Taille')}</span>
        <div class="gabarits">${gabaritsHTML(max, v, (l, h) => `Disposition.taille('v${i}', ${l}, ${h})`)}</div>
      </div>
      <div class="ligne-actions">
        <button class="secondaire danger" onclick="Disposition.retireVide(${i})">
          ${t('Retirer cette case')}</button>
      </div>
    </div>`;
}

function caseHTML(c) {
  const t = c.decouvert;
  const q = c.rarete || 2;
  const img = t ? imageDeCase(c) : null;
  const dedans = img?.chemin
    ? `<img class="${img.detouree ? 'decoupe' : 'pleine'}"
            src="${image(img.chemin)}" alt="" loading="lazy">`
    : silhouetteHTML(c.visuel);
  return `
    <div class="case-dex" onclick="ouvreFiche(${c.id})">
      <div class="vignette ${t ? 'trouvee' : ''} q${q}">${dedans}</div>
      <div class="nom">${t ? echappe(c.nom) : '???'}</div>
    </div>`;
}

/* La silhouette. Le `mask` reteinte le SVG en aplat gris uniforme, comme le
 * `ColorFilter.srcIn` de l'application : le tracé de PhyloPic garde parfois
 * des détails clairs qu'on ne veut pas voir ici. */
function silhouetteHTML(visuel) {
  if (!visuel) return '<span class="sans-visuel">?</span>';
  return `<span class="silhouette" style="-webkit-mask-image:url('${image(visuel)}');
            mask-image:url('${image(visuel)}')"></span>`;
}

/* La pastille de qualité : le nom du palier dans sa couleur, sur un fond de la
 * même teinte très dilué. Une étoile à partir de « rare ». */
function pastilleRarete(rarete, points) {
  const q = rarete || 2;
  const etoile = q >= 5 ? '✦' : q >= 4 ? '★' : '';
  return `<span class="pastille q${q}">${etoile ? `${etoile} ` : ''}${
    QUALITES[q]}${points != null ? ` ${t('· {0} pts', [points])}` : ''}</span>`;
}

function pastilleRegne(cle) {
  const r = regneDe(cle);
  return `<span class="pastille-regne" style="--c:${r.couleur}">${r.emoji} ${r.nom}</span>`;
}

/* Le bandeau de rang, en tête du dex.
 *
 * Il remplace un « 3 sur 977 415 » qui ne disait qu'une chose : qu'on n'y
 * arriverait jamais. Ici tout est à portée — le rang qu'on porte, les points,
 * et combien d'espèces avant le suivant. */
/* La bascule entre les deux bandeaux, posée sur le coin de l'écusson.
 *
 * En surimpression plutôt qu'à côté : elle ne prend aucune place dans un
 * en-tête déjà chargé, et elle est là où l'œil se pose déjà. Le pictogramme
 * montre ce vers quoi on va, pas ce qu'on regarde. */
function basculeBandeau(surVitrine) {
  return `<button class="bascule-bandeau" title="${
    surVitrine ? 'Voir le rang du dex' : t('Voir ma vitrine')}"
    onclick="event.stopPropagation(); basculeVitrine()">${
    surVitrine ? '🎖' : '💎'}</button>`;
}

/* Le bandeau de la vitrine, jumeau de celui du rang.
 *
 * Même place, même hauteur : la bascule ne doit pas faire sauter ce qui est en
 * dessous. Ce qu'il dit est différent — le rang compte les espèces, la vitrine
 * ne regarde que les dix meilleures. Un joueur à deux cents banalités monte au
 * dex et stagne ici. */
function bandeauVitrine() {
  const v = etat.vitrine;
  if (!v) return bandeauPalier();
  const r = v.rang;
  const part = r.objectif && r.objectif > r.depuis
    ? Math.max(0, Math.min(1, (v.score - r.depuis) / (r.objectif - r.depuis)))
    : 1;
  return `
    <div class="palier vitrine" onclick="va('vitrine')">
      <div class="piece-coin">
        <div class="piece">${Media.modele(56, { noir: !v.pieces.length })}</div>
        ${basculeBandeau(true)}
      </div>
      <div class="corps">
        <div class="haut">
          <b>${echappe(r.nom)}</b>
          <span class="doux">#${r.numero}/${r.total_paliers}</span>
        </div>
        <div class="comptes doux">
          <span>${t('🏅 {0} pts de vitrine', [v.score])}</span>
          <span>${t('{0}/{1} pièce{2}', [v.pieces.length, v.taille, 
            v.pieces.length > 1 ? 's' : ''])}</span>
        </div>
        ${r.suivant ? `
          <div class="jauge violette"><div style="width:${(part * 100).toFixed(1)}%"></div></div>
          <div class="doux reste">${t('Encore {0} pts avant {1}', [r.reste, echappe(r.suivant)])}</div>`
          : `<div class="max">${t('Vitrine complète.')}</div>`}
      </div>
    </div>`;
}

async function chargeVitrine() {
  try {
    etat.vitrine = await appel('/vitrine');
  } catch (e) {
    // Sans vitrine, le bandeau du rang reste affiché : c'est un supplément,
    // pas une information dont l'écran dépend.
    etat.bandeauVitrine = false;
  }
  dessine();
}

function basculeVitrine() {
  etat.bandeauVitrine = !etat.bandeauVitrine;
  localStorage.setItem('biodex_bandeau_vitrine', etat.bandeauVitrine ? '1' : '0');
  if (etat.bandeauVitrine && !etat.vitrine) chargeVitrine();
  else dessine();
}

/* L'écran de la vitrine : la pièce en trois dimensions, et ce qui l'a méritée.
 *
 * La pièce se manipule au doigt et tourne seule quand on la lâche. Ce n'est
 * pas un vrai moteur 3D — vingt-quatre images pré-rendues — mais à l'usage la
 * différence ne se voit pas, et on n'embarque ni WebGL ni chargeur glTF. */
async function chargeSucces() {
  try { etat.succes = await appel('/succes'); }
  catch (e) { signale(e.message, true); etat.succes = { succes: [], obtenus: 0, total: 0, nouveaux: [] }; }
  dessine();
}

/* Révéler la condition d'un succès qu'on n'a pas.
 *
 * Le serveur n'envoie pas le texte tant qu'on ne l'a pas demandé : le cacher
 * seulement à l'affichage laisserait la condition lisible dans la réponse,
 * ce qui n'est pas un secret gardé. */
async function reveleSucces(cle) {
  try {
    const d = await appel(`/succes/${cle}/reveler`, { method: 'POST', body: {} });
    const s = etat.succes.succes.find((x) => x.cle === cle);
    if (s) { s.comment = d.comment; s.revele = true; }
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* Un `model-viewer` ouvert accapare le processeur graphique. Tant qu'il est à
 * l'écran, les canevas animés de la grille derrière ne servent à rien — on ne
 * les voit pas — et leur coût se lit directement sur la fluidité du modèle. */
let veilleFiche = false;

function veillePourLa3D(actif) {
  if (actif === veilleFiche) return;
  veilleFiche = actif;
  if (actif) Media.endors(); else Media.reveilleTout();
}

function ouvreSucces(cle) {
  const s = etat.succes?.succes.find((x) => x.cle === cle);
  // Un succès qu'on vient de décrocher et qu'on n'a jamais ouvert arrive
  // enfermé dans sa gemme. Une fois brisée, la fiche s'ouvre normalement :
  // rejouer l'animation à chaque visite en ferait un péage.
  if (s?.obtenu && !dejaOuverts().has(cle)) { ouvreCristal(cle); return; }
  etat.succesOuvert = cle;
  dessine();
}

/* La fiche d'un succès : le modèle en grand, et la condition — ou son
 * absence assumée. */
function vueFicheSucces() {
  if (!etat.succesOuvert || !etat.succes) return '';
  const s = etat.succes.succes.find((x) => x.cle === etat.succesOuvert);
  if (!s) return '';
  return `<div class="voile-modale" onclick="if(event.target===this)ferme('succesOuvert')">
    <div class="modale fiche-succes">
      <div class="grand-modele">
        ${s.obtenu ? `
          <!-- Débloqué : le vrai rendu 3D, avec son éclairage et son ombre.
               C'est l'écran qu'on ouvre exprès pour regarder la pièce — le
               seul endroit où le rendu complet se justifie. -->
          <model-viewer
            src="media/${s.modele}.glb"
            poster="media/${s.modele}_apercu.webp"
            alt="${echappe(s.nom)}"
            camera-controls auto-rotate
            camera-orbit="0deg 72deg 105%"
            field-of-view="30deg"
            auto-rotate-delay="1200"
            rotation-per-second="18deg"
            shadow-intensity="1"
            exposure="1.05"
            ar ar-modes="webxr scene-viewer quick-look"
            touch-action="pan-y" disable-pan
            min-camera-orbit="auto auto 60%"
            max-camera-orbit="auto auto 200%"
          ></model-viewer>`
        : `<!-- Verrouillé : la silhouette suffit, et charger un demi-mégaoctet
                de glTF pour la peindre en noir serait absurde. -->
           ${Media.modele(150, { noir: true, doigt: false, modele: s.modele })}`}
      </div>
      <h2>${s.emoji} ${echappe(s.nom)}</h2>
      ${s.obtenu
        ? `<p class="obtenu-le">${t('Débloqué le {0}', [(s.obtenu_le || '').split(' ')[0]])}</p>`
        : (s.avancement != null && s.seuil > 1
          ? `<p class="doux">${t('{0} sur {1}', [s.avancement, s.seuil])}</p>` : '')}
      ${s.comment
        ? `<p class="condition">${echappe(s.comment)}</p>`
        : `<p class="condition cachee">${t('La condition est cachée. À toi de deviner — ou de regarder, si tu préfères savoir.')}</p>
           <button class="lien" onclick="reveleSucces('${s.cle}')">
             ${t('👁 Comment le débloquer ?')}</button>`}
      <button class="primaire" onclick="ferme('succesOuvert')">${t('Fermer')}</button>
    </div>
  </div>`;
}

function vueVitrine() {
  const v = etat.vitrine;
  if (!v) { if (!etat.chargeVitrine) { etat.chargeVitrine = true; chargeVitrine(); }
    return Media.chargement(); }
  if (!etat.succes && !etat.chargeSucces) { etat.chargeSucces = true; chargeSucces(); }
  const r = v.rang;
  // Le vrai `model-viewer` ici, et pas les images pré-rendues : c'est l'écran
  // qu'on ouvre exprès pour regarder la pièce, il mérite l'éclairage,
  // l'ombre portée et la réalité augmentée. Les vingt-quatre images restent
  // pour la vignette du bandeau et la grille des rangs, où cinquante contextes
  // WebGL feraient chauffer le téléphone pour rien.
  //
  // `poster` est l'image pré-rendue : elle s'affiche pendant que le modèle
  // charge, ce qui évite le carré vide sur un réseau lent.
  // Plus de gros modèle en tête.
  //
  // Il y trônait, et deux choses n'allaient pas. Il fait doublon : la grille
  // en dessous montre déjà trente modèles. Et surtout, `camera-controls`
  // capte le geste — on essayait de faire défiler la page en glissant dessus,
  // la grenouille tournait et la page ne bougeait pas. Le vrai rendu 3D reste
  // là où on l'ouvre exprès : dans la fiche d'un succès.
  return `
    <section class="bloc">
      <h2 class="titre-vitrine">${echappe(r.nom)}</h2>
      <p class="doux">${t('Rang {0} sur {1} · {2} points', [r.numero, r.total_paliers, v.score])}</p>
      ${r.suivant ? `<p class="doux">${t('Encore {0} pts avant {1}', [r.reste, echappe(r.suivant)])}</p>` : ''}
      <p class="doux explication">
        ${t('La vitrine ne compte que vos {0} plus belles trouvailles. Le rang du dex, lui, compte toutes les espèces.', [v.taille])}</p>
    </section>
    ${grilleSucces()}
    <h3 class="section">${t('Les {0} pièces qui comptent', [v.taille])}</h3>
    ${v.pieces.length ? `<ol class="pieces">${v.pieces.map((x, i) => `
      <li>
        <span class="rang">${i + 1}</span>
        ${x.vignette || x.decoupe
          ? `<img class="prise" src="${image(photoDePiece(x))}" alt="" loading="lazy">`
          : '<span class="prise vide"></span>'}
        <span class="nom">
          <b>${echappe(x.nom)}</b>
          <i class="doux">${echappe(x.latin)}</i>
        </span>
        <span class="pts q${x.qualite}">${t('{0} pts', [x.points])}</span>
      </li>`).join('')}</ol>`
      : `<p class="doux vide-mot">${t('Rien encore. La première espèce trouvée ouvrira la vitrine.')}</p>`}
    ${v.pieces.length >= v.taille
      ? `<p class="doux explication">${t('La vitrine est pleine : désormais, seule une prise meilleure que la dernière fait monter le score.')}</p>` : ''}`;
}

/* Détourée ou entière : le même réglage que les cases du dex. Une vitrine qui
 * montrerait ses prises autrement que son dex serait déroutante. */
/* Les trente succès, groupés par difficulté.
 *
 * Verrouillé, on montre le modèle en silhouette noire, le nom et l'emoji —
 * jamais la condition. On doit pouvoir deviner, et choisir de ne pas savoir. */
function grilleSucces() {
  const p = etat.succes;
  if (!p) return Media.chargement(60);
  const neufs = new Set(p.nouveaux || []);

  return `
    <div class="compte-succes">
      <b>${p.obtenus} / ${p.total}</b> <span class="doux">${t('succès')}</span>
      ${neufs.size ? `<span class="tombe">${neufs.size === 1
        ? t('Un succès vient de tomber.')
        : `${t('{0} succès viennent de tomber.', [neufs.size])}`}</span>` : ''}
    </div>
    <div class="grille-succes">${p.succes.map((s) => `
      <button class="succes ${s.obtenu ? 'acquis' : ''} ${
        neufs.has(s.cle) ? 'tombe' : ''}"
              style="--teinte-succes:${echappe((s.couleurs || COULEURS_DEFAUT).corps)}"
              onclick="ouvreSucces('${s.cle}')">
        ${Media.modele(0, { noir: !s.obtenu, auto: neufs.has(s.cle),
                            classe: 'remplit', modele: s.modele })}
        <span class="nom">${s.emoji} ${echappe(s.nom)}</span>
        ${!s.obtenu && s.avancement != null && s.seuil > 1 ? `
          <span class="part"><i style="width:${
            Math.min(100, Math.round(s.avancement / s.seuil * 100))}%"></i></span>` : ''}
        ${s.obtenu ? '<span class="sceau">✓</span>' : ''}
      </button>`).join('')}</div>`;
}

/* La photo à montrer pour une prise — détourée ou entière selon le réglage
 * « Cases en photo entière ». Le réglage vaut partout où une bête s'affiche
 * en vignette : il ne s'appliquait qu'à la grille du dex, et la fiche d'une
 * espèce revenait au détourage alors qu'on venait de cocher l'inverse. */
function photoDePiece(x) {
  return etat.casesEntieres ? (x.vignette || x.decoupe) : (x.decoupe || x.vignette);
}

/* --------------------------------------------------- espèces des joueurs
 *
 * Le moteur rend « Rosa gallica » pour tous les cultivars d'une roseraie :
 * ces plantes ne sont pas des taxons, elles n'existent nulle part dans le
 * backbone et n'y existeront jamais.
 *
 * La règle que tout le reste sert : **on ajoute à la base, pas au modèle.**
 * La case apparaît au dex, tout le monde la voit, on y range ses photos à la
 * main — mais aucune analyse ne la proposera. */

function ouvreNouvelleEspece(existante = null) {
  etat.nouvelleEspece = existante
    ? { id: existante.id, nom: existante.nom, latin: existante.latin || '',
        regne: existante.regne, description: existante.resume || '',
        wikipedia: existante.wikipedia || '', trouve: '', envoi: false }
    : { id: null, nom: '', latin: '', regne: 'plante', description: '',
        wikipedia: '', trouve: '', envoi: false };
  dessine();
}

function champEspece(champ, valeur) {
  if (etat.nouvelleEspece) etat.nouvelleEspece[champ] = valeur;
}

/* Regarder ce que le lien donne, sans rien créer.
 *
 * On montre le résultat avant d'enregistrer : coller une adresse ne doit
 * jamais fabriquer une case que personne n'a relue. */
async function essaieLeLien() {
  const e = etat.nouvelleEspece;
  if (!e || !e.wikipedia.trim()) return;
  e.charge = true; e.trouve = ''; dessine();
  try {
    const d = await appel(`/especes/apercu?lien=${encodeURIComponent(e.wikipedia.trim())}`);
    if (!e.nom.trim()) e.nom = d.nom_fr || d.titre || '';
    if (!e.latin.trim() && d.latin) e.latin = d.latin;
    if (!e.description.trim() && d.resume) e.description = d.resume;
    e.trouve = d.latin
      ? `${t('Taxon reconnu : {0}', [d.latin])}`
      // Le cas du cultivar, dit franchement : l'article existe mais ne décrit
      // pas un taxon. On a pris le titre et le résumé, rien de plus.
      : t('Article trouvé, mais ce n\'est pas un taxon référencé.')
        + t('Le titre et le résumé ont été repris.');
  } catch (err) {
    signale(err.message, true);
  } finally { e.charge = false; dessine(); }
}

async function valideEspece() {
  const e = etat.nouvelleEspece;
  if (!e || e.nom.trim().length < 2) { signale(t('Il faut au moins un nom.'), true); return; }
  e.envoi = true; dessine();
  try {
    const corps = { nom: e.nom.trim(), description: e.description.trim(),
                    wikipedia: e.wikipedia.trim() };
    if (e.id) await appel(`/especes/${e.id}`, { method: 'PATCH', body: corps });
    else await appel('/especes', { method: 'POST',
      body: { ...corps, regne: e.regne, latin: e.latin.trim() } });
    etat.nouvelleEspece = null;
    signale(e.id ? 'Espèce mise à jour.' : t('Espèce ajoutée au dex.'));
    if (etat.mesEspeces) chargeMesEspeces();
    dessine();
  } catch (err) {
    e.envoi = false;
    signale(err.message, true);
    dessine();
  }
}

function vueNouvelleEspece() {
  const e = etat.nouvelleEspece;
  if (!e) return '';
  return `
    <div class="plein">
      <header>
        <button class="retour" onclick="ferme('nouvelleEspece')" aria-label="${t('Retour')}">
          <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
            <path d="M15.4 7.4L14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg></button>
        <h1>${e.id ? "Modifier l'espèce" : t('Nouvelle espèce')}</h1>
      </header>
      <div class="formulaire">
        <p class="doux explication">
          ${t('Cette espèce entrera au dex et tout le monde la verra. Elle ne sera jamais proposée par une analyse : le moteur n\'a pas appris à la reconnaître, et ne l\'apprendra pas. On l\'y range à la main.')}</p>

        ${e.id ? '' : `
          <label class="etiquette">${t('Règne')}</label>
          <div class="regnes">${REGNES_APP.map((r) => `
            <button class="carte-regne ${e.regne === r.cle ? 'actif' : ''}"
                    style="--c:${r.couleur}"
                    onclick="champEspece('regne','${r.cle}'); dessine()">
              <span>${r.emoji}</span><b>${r.nom}</b></button>`).join('')}</div>`}

        <label class="etiquette">${t('Nom *')}</label>
        <input value="${echappe(e.nom)}" placeholder="${t('Rosier Sophie Vartan')}"
               oninput="champEspece('nom', this.value)">

        ${e.id ? '' : `
          <label class="etiquette">${t('Nom latin')}</label>
          <input value="${echappe(e.latin)}" placeholder="${t('Laissé vide, le nom sert de référence')}"
                 autocapitalize="off" oninput="champEspece('latin', this.value)">`}

        <label class="etiquette">${t('Article Wikipédia')}</label>
        <div class="avec-bouton">
          <input value="${echappe(e.wikipedia)}" inputmode="url" autocapitalize="off"
                 placeholder="${'https://fr.wikipedia.org/wiki/…'}"
                 oninput="champEspece('wikipedia', this.value)">
          <button onclick="essaieLeLien()" ${e.charge ? 'disabled' : ''}
                  title="${t('Remplir depuis l\'article')}">${e.charge ? '…' : '↓'}</button>
        </div>
        ${e.trouve ? `<p class="doux trouve">${echappe(e.trouve)}</p>` : ''}

        <label class="etiquette">${t('Description')}</label>
        <textarea rows="6" oninput="champEspece('description', this.value)"
        >${echappe(e.description)}</textarea>

        <button class="primaire" onclick="valideEspece()" ${e.envoi ? 'disabled' : ''}>
          ${e.id ? 'Enregistrer' : t('Ajouter au dex')}</button>
        <p class="doux explication">
          ${t('Vous pourrez la retirer si elle s\'avère fausse. Tant que personne n\'y a rangé de photo, elle disparaîtra complètement ; ensuite elle sera seulement désactivée, pour ne pas emporter le travail des autres.')}</p>
      </div>
    </div>`;
}

async function chargeMesEspeces() {
  try {
    const d = await appel('/especes/miennes');
    etat.mesEspeces = d.especes;
  } catch (e) { signale(e.message, true); }
  dessine();
}

async function retireEspece(id, captures, nom) {
  const mot = captures
    ? `${t('{0} photo{1}.', [captures, captures > 1 ? 's y sont rangées' : t('y est rangée')])} `
      + t('L\'espèce sera désactivée, pas supprimée : les photos resteront où')
      + t('elles sont, et vous pourrez la remettre.')
    : t('Personne n\'y a rangé de photo : elle disparaîtra complètement du dex.');
  if (!confirm(`${t('Retirer « {0} » ?\\n\\n{1}', [nom, mot])}`)) return;
  try {
    await appel(`/especes/${id}`, { method: 'DELETE' });
    chargeMesEspeces();
  } catch (e) { signale(e.message, true); }
}

async function reactiveEspece(id) {
  try {
    await appel(`/especes/${id}/reactive`, { method: 'POST', body: {} });
    chargeMesEspeces();
  } catch (e) { signale(e.message, true); }
}

function vueMesEspeces() {
  const l = etat.mesEspeces;
  if (l === null) { chargeMesEspeces(); etat.mesEspeces = undefined; return Media.chargement(); }
  if (l === undefined) return Media.chargement();
  return `
    <div class="rangee-centree haut-page">
      <button class="primaire" onclick="ouvreNouvelleEspece()">${t('＋ Ajouter une espèce')}</button>
    </div>
    ${l.length ? `<ul class="mes-especes">${l.map((e) => `
      <li class="${e.actif ? '' : 'retiree'}">
        <div class="corps">
          <b>${echappe(e.nom)}${e.actif ? '' : ` <i class="retiree-mot">${t('retirée')}</i>`}</b>
          <span class="doux">${[
            e.latin, e.captures ? `${t('{0} photo{1}', [e.captures, e.captures > 1 ? 's' : ''])}` : '',
            e.wikipedia ? 'Wikipédia' : ''].filter(Boolean).map(echappe).join(' · ')}</span>
        </div>
        ${e.actif
          ? `<button class="outil" title="${t('Modifier')}"
               onclick='ouvreNouvelleEspece(${JSON.stringify(e).replace(/'/g, "&#39;")})'>✎</button>
             <button class="outil danger" title="${t('Retirer')}"
               onclick="retireEspece(${e.id}, ${e.captures}, '${echappe(e.nom).replace(/'/g, "&#39;")}')">🗑</button>`
          : `<button class="outil" title="${t('Remettre')}"
               onclick="reactiveEspece(${e.id})">↺</button>`}
      </li>`).join('')}</ul>`
      : `<div class="vide-bloc">
           <p><b>${t('Rien indexé pour l\'instant.')}</b></p>
           <p class="doux">${t('Quand le moteur se trompe parce qu\'il ne connaît pas l\'espèce — un cultivar de rosier, une race, une variété — ajoutez-la vous-même. Elle entrera au dex pour tout le monde.')}</p>
         </div>`}`;
}

/* ------------------------------------------------- réglages de notification
 *
 * Le serveur filtre à l'écriture, pas à la lecture : une notification qu'on
 * n'a pas voulue n'existe pas. Cet écran ne fait donc que dire au serveur ce
 * qu'on accepte — il ne masque rien après coup. */
async function chargeReglagesNotifs() {
  try { etat.reglagesNotifs = await appel('/notifications/reglages'); }
  catch (e) { signale(e.message, true); }
  dessine();
}

async function basculeNotif(cle, valeur) {
  const r = etat.reglagesNotifs;
  if (!r) return;
  const c = r.categories.find((x) => x.cle === cle);
  if (!c) return;
  const avant = c.actif;
  c.actif = valeur;   // on bascule tout de suite, on corrige si ça rate
  dessine();
  try {
    // Le serveur attend l'état de toutes les catégories et ne retient que les
    // écarts au défaut : ce qu'on ne touche pas suivra les évolutions de
    // l'application au lieu d'être figé au jour de l'installation.
    const reglages = {};
    r.categories.forEach((x) => { reglages[x.cle] = x.actif; });
    await appel('/notifications/reglages', { method: 'PUT', body: { reglages } });
  } catch (e) {
    c.actif = avant;
    signale(e.message, true);
    dessine();
  }
}

function vueReglagesNotifs() {
  const r = etat.reglagesNotifs;
  if (!r) { chargeReglagesNotifs(); etat.reglagesNotifs = undefined; return Media.chargement(); }
  if (r === undefined) return Media.chargement();
  return `
    <p class="doux explication" style="padding:4px 16px 0">
      ${t('Sobre par défaut : seulement ce qui vous concerne. Ce qui est décoché n\'est pas masqué, il n\'est jamais écrit.')}</p>
    <ul class="reglages">${r.categories.map((c) => `
      <li>
        <div class="corps">
          <b>${echappe(c.nom)}</b>
          <span class="doux">${echappe(c.detail)}</span>
        </div>
        <label class="interrupteur">
          <input type="checkbox" ${c.actif ? 'checked' : ''}
                 onchange="basculeNotif('${c.cle}', this.checked)">
          <span></span>
        </label>
      </li>`).join('')}</ul>`;
}

function bandeauPalier() {
  const r = etat.resume;
  if (!r?.palier) return '';
  const p = r.palier;
  const part = p.objectif && p.suivant
    ? Math.max(0, Math.min(1, (r.trouve - p.depuis) / Math.max(1, p.objectif - p.depuis)))
    : 1;
  return `
    <div class="palier" onclick="va('paliers')">
      <div class="piece-coin">
        <img class="ecusson ${p.numero === 0 ? 'eteint' : ''}"
             src="${image(p.badge)}" alt="">
        ${basculeBandeau(false)}
      </div>
      <div class="corps">
        <div class="haut">
          <b>${echappe(p.nom)}</b>
          <span class="doux">#${p.numero}/${p.total_paliers}</span>
        </div>
        <div class="comptes doux">
          <span>${t('🐾 {0} espèce{1}', [r.trouve, r.trouve > 1 ? 's' : ''])}</span>
          <span>${t('☆ {0} pts{1}', [r.points, r.points_reactions
            ? ` ${t('(dont {0} 👏)', [r.points_reactions])}` : ''])}</span>
        </div>
        ${p.suivant ? `
          <div class="jauge"><div style="width:${(part * 100).toFixed(1)}%"></div></div>
          <div class="doux reste">${t('Encore {0} espèce{1} avant {2}', [p.reste, 
            p.reste > 1 ? 's' : '', echappe(p.suivant)])}</div>`
          : `<div class="max">${t('Rang maximal atteint.')}</div>`}
      </div>
      ${p.badge_suivant
        ? `<img class="ecusson suivant" src="${image(p.badge_suivant)}" alt="">` : ''}
    </div>`;
}

function vueDex() {
  const nb = etat.nbFiltres;
  return `
    <div class="entete-dex">
      <h1>${t('Mon dex')}</h1>
      <button class="outil" onclick="va('carte')" aria-label="${t('Carte')}">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="none"
             stroke="currentColor" stroke-width="1.8">
          <circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/>
          <path d="M3.5 9h17M3.5 15h17"/></svg>
      </button>
      <button class="outil ${nb ? 'allume' : ''}" onclick="ouvreFiltres()"
              aria-label="${t('Filtrer et trier')}">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
          <path d="M3 6h12v2H3zm0 5h9v2H3zm0 5h6v2H3zm14-9h4v2h-4zm-3 5h7v2h-7zm-3 5h10v2H11z"/></svg>
        ${nb ? `<i class="compteur">${nb}</i>` : ''}
      </button>
      <label class="champ-recherche">
        <svg viewBox="0 0 24 24" width="17" height="17" fill="currentColor">
          <path d="M15.5 14h-.8l-.3-.3a6.5 6.5 0 10-.7.7l.3.3v.8l5 5 1.5-1.5-5-5zm-6 0a4.5 4.5 0 110-9 4.5 4.5 0 010 9z"/></svg>
        <input placeholder="${t('Chercher…')}" value="${echappe(etat.recherche)}"
               oninput="cherche(this.value)">
        ${etat.recherche ? `<button onclick="cherche('');dessine()">✕</button>` : ''}
      </label>
    </div>

    ${etat.bandeauVitrine ? bandeauVitrine() : bandeauPalier()}

    <div class="puces">
      <button class="puce ${!etat.regne ? 'actif' : ''}" style="--c:var(--accent)"
              onclick="filtreRegne(null)">${t('Tout')}</button>
      ${REGNES_APP.map((r) => `
        <button class="puce ${etat.regne === r.cle ? 'actif' : ''}" style="--c:${r.couleur}"
                onclick="filtreRegne('${r.cle}')">${r.emoji} ${r.nom}</button>`).join('')}
    </div>

    <div class="segments">
      ${[['collection', t('Cases')], ['arbre', t('Groupes')], ['recent', t('Récent')]]
        .map(([k, n]) => `
        <button class="${etat.mode === k ? 'actif' : ''}"
                onclick="changeMode('${k}')">${n}</button>`).join('')}
    </div>

    ${etat.classe ? filAriane() : ''}
    ${corpsDex()}`;
}

function filAriane() {
  const etapes = [[nomDeTaxon(etat.classe), 0]];
  if (etat.ordre) etapes.push([nomDeTaxon(etat.ordre), 1]);
  if (etat.famille) etapes.push([nomDeTaxon(etat.famille), 2]);
  return `
    <div class="ariane">
      <button onclick="remonte(-1)">${t('Tout')}</button>
      ${etapes.map(([n, i]) => `<span>›</span>
        <button onclick="remonte(${i})">${echappe(n)}</button>`).join('')}
    </div>`;
}

function corpsDex() {
  if (etat.charge && !etat.trouvees.length && !etat.aTrouver.length
      && !etat.noeuds.length) {
    return Media.chargement();
  }
  if (etat.mode === 'arbre') return vueArbre();
  if (etat.mode === 'recent') return vueRecent();

  if (etat.recherche) {
    return etat.trouvees.length
      ? `${titreSection(`${t('{0} résultat{1}', [etat.trouvees.length, 
           etat.trouvees.length > 1 ? 's' : ''])}`)}
         <div class="grille-dex">${etat.trouvees.map(caseHTML).join('')}</div>`
      : messageVide(t('Rien ici'), t('Aucune espèce ne correspond.'));
  }
  if (!etat.trouvees.length && !etat.aTrouver.length) {
    return messageVide(t('Rien ici'), t('Aucune espèce ne correspond.'));
  }
  return `
    ${etat.trouvees.length ? `
      ${Disposition.actif() ? barreArrangement()
        : titreSection(`${t('Trouvées ({0})', [etat.trouvees.length])}`, null,
            `<button class="lien" onclick="Disposition.entre(etat.trouvees)">${t('⠿ Ranger')}</button>`)}
      ${grilleTrouvees()}` : ''}
    ${etat.aTrouver.length ? `
      ${titreSection(t('À découvrir'), t('Les plus fréquentes que vous n\'avez pas encore.'))}
      <div class="grille-dex">${etat.aTrouver.map(caseHTML).join('')}</div>` : ''}
    <div style="height:28px"></div>`;
}

/* `action` est du HTML déjà construit, posé à droite du titre. */
const titreSection = (t, d, action = '') => `
  <div class="titre-section ${action ? 'avec-action' : ''}">
    <span class="col">
      <b>${echappe(t)}</b>
      ${d ? `<span class="doux">${echappe(d)}</span>` : ''}
    </span>
    ${action}
  </div>`;

/* `action` est du HTML déjà construit — un bouton de sortie quand le vide est
 * une impasse dont il faut pouvoir revenir. Il n'est donc pas échappé, à la
 * différence du titre et du détail : ne jamais lui passer du texte venant du
 * serveur ou du joueur. */
const messageVide = (titre, detail, action = '') => `
  <div class="message">
    <b>${echappe(titre)}</b>
    <span class="doux">${echappe(detail)}</span>
    ${action}
  </div>`;

/* La descente classe → ordre → famille, avec l'avancement de chaque branche. */
function vueArbre() {
  if (!etat.noeuds.length) {
    return messageVide(t('Rien ici'), t('Aucun groupe à ce niveau.'));
  }
  return `<div class="branches">${etat.noeuds.map((n) => {
    const part = n.total ? n.trouve / n.total : 0;
    return `
      <button class="branche" onclick="descend('${echappe(n.nom)}')">
        <span class="texte">
          <b>${echappe(nomDeTaxon(n.nom))}</b>
          <span class="doux">${n.trouve} / ${n.total}</span>
        </span>
        <span class="jauge"><span style="width:${(part * 100).toFixed(1)}%"></span></span>
        <span class="doux">›</span>
      </button>`;
  }).join('')}</div>`;
}

function vueRecent() {
  if (!etat.trouvees.length) {
    return messageVide(t('Rien encore'), t('Tes trouvailles apparaîtront ici.'));
  }
  return `<div class="recentes">${etat.trouvees.map((c) => `
    <div class="ligne" onclick="ouvreFiche(${c.id})">
      <div class="case-dex compacte">
        <div class="vignette trouvee q${c.rarete || 2}">
          ${c.decoupe ? `<img class="decoupe" src="${image(c.decoupe)}" alt="">`
            : (c.vignette ? `<img class="pleine" src="${image(c.vignette)}" alt="">`
              : silhouetteHTML(c.visuel))}
        </div>
      </div>
      <span class="texte">
        <b>${echappe(c.nom)}</b>
        <span class="doux latin">${echappe(c.latin)}</span>
        <span class="doux">${quand(c.trouve_le)}</span>
      </span>
      ${pastilleRarete(c.rarete, c.points)}
    </div>`).join('')}</div>`;
}

/* Les noms courants des grands groupes, repris de `modeles.dart`.
 *
 * « Aves » ne dit rien à personne, « Oiseaux » si. On ne traduit que ce qui a
 * un nom courant honnête ; le reste garde son latin, ce qui vaut mieux qu'une
 * traduction inventée. */
const NOMS_CLASSES = {
  "Insecta": t('Insectes'),
  "Aves": t('Oiseaux'),
  "Mammalia": t('Mammifères'),
  "Amphibia": t('Amphibiens'),
  "Squamata": t('Lézards et serpents'),
  "Actinopterygii": t('Poissons'),
  "Actinopteri": t('Poissons'),
  "Chondrichthyes": t('Requins et raies'),
  "Arachnida": t('Araignées'),
  "Gastropoda": t('Escargots'),
  "Bivalvia": t('Coquillages'),
  "Malacostraca": t('Crustacés'),
  "Chilopoda": t('Mille-pattes'),
  "Diplopoda": t('Mille-pattes'),
  "Clitellata": t('Vers'),
  "Polychaeta": t('Vers marins'),
  "Anthozoa": t('Coraux et anémones'),
  "Scyphozoa": t('Méduses'),
  "Hydrozoa": t('Hydres'),
  "Asteroidea": t('Étoiles de mer'),
  "Echinoidea": t('Oursins'),
  "Testudines": t('Tortues'),
  "Reptilia": t('Reptiles'),
  "Collembola": t('Collemboles'),
  "Ostracoda": t('Ostracodes'),
  "Maxillopoda": t('Copépodes'),
  "Branchiopoda": t('Branchiopodes'),
};
const NOMS_TAXONS = {
  "Artiodactyla": t('Ongulés'),
  "Carnivora": t('Carnivores'),
  "Rodentia": t('Rongeurs'),
  "Chiroptera": t('Chauves-souris'),
  "Primates": t('Primates'),
  "Lagomorpha": t('Lapins et lièvres'),
  "Cetacea": t('Baleines et dauphins'),
  "Soricomorpha": t('Musaraignes'),
  "Eulipotyphla": t('Insectivores'),
  "Perissodactyla": t('Chevaux et rhinocéros'),
  "Diprotodontia": t('Marsupiaux'),
  "Proboscidea": t('Éléphants'),
  "Passeriformes": t('Passereaux'),
  "Anseriformes": t('Canards et oies'),
  "Accipitriformes": t('Rapaces'),
  "Falconiformes": t('Faucons'),
  "Strigiformes": t('Chouettes et hiboux'),
  "Charadriiformes": t('Limicoles et mouettes'),
  "Pelecaniformes": t('Hérons et pélicans'),
  "Columbiformes": t('Pigeons'),
  "Galliformes": t('Gallinacés'),
  "Piciformes": t('Pics'),
  "Apodiformes": t('Martinets et colibris'),
  "Ciconiiformes": t('Cigognes'),
  "Gruiformes": t('Grues et râles'),
  "Lepidoptera": t('Papillons'),
  "Coleoptera": t('Coléoptères'),
  "Hymenoptera": t('Abeilles, guêpes et fourmis'),
  "Diptera": t('Mouches et moustiques'),
  "Odonata": t('Libellules'),
  "Orthoptera": t('Sauterelles et criquets'),
  "Hemiptera": t('Punaises'),
  "Araneae": t('Araignées'),
  "Decapoda": t('Crabes et crevettes'),
  "Anura": t('Grenouilles et crapauds'),
  "Caudata": t('Tritons et salamandres'),
  "Testudines": t('Tortues'),
  "Serpentes": t('Serpents'),
  "Crocodylia": t('Crocodiles'),
  "Cervidae": t('Cervidés'),
  "Bovidae": t('Bovidés'),
  "Felidae": t('Félins'),
  "Canidae": t('Canidés'),
  "Ursidae": t('Ours'),
  "Mustelidae": t('Mustélidés'),
  "Sciuridae": t('Écureuils'),
  "Muridae": t('Souris et rats'),
  "Suidae": t('Sangliers et porcs'),
  "Equidae": t('Chevaux'),
  "Leporidae": t('Lapins et lièvres'),
  "Paridae": t('Mésanges'),
  "Corvidae": t('Corvidés'),
  "Anatidae": t('Canards'),
  "Turdidae": t('Grives et merles'),
  "Fringillidae": t('Fringilles'),
  "Laridae": t('Mouettes et goélands'),
  "Ardeidae": t('Hérons'),
  "Accipitridae": t('Aigles et buses'),
  "Strigidae": t('Chouettes'),
  "Picidae": t('Pics'),
  "Hirundinidae": t('Hirondelles'),
  "Lacertidae": t('Lézards'),
  "Colubridae": t('Couleuvres'),
  "Viperidae": t('Vipères'),
  "Ranidae": t('Grenouilles vraies'),
  "Bufonidae": t('Crapauds'),
  "Salamandridae": t('Salamandres et tritons'),
  "Coccinellidae": t('Coccinelles'),
  "Apidae": t('Abeilles'),
  "Formicidae": t('Fourmis'),
  "Nymphalidae": t('Papillons nymphalidés'),
  "Pieridae": t('Piérides'),
  "Papilionidae": t('Machaons'),
  "Carabidae": t('Carabes'),
  "Libellulidae": t('Libellules'),
  "Helicidae": t('Escargots'),
};

const nomDeClasse = (l) => NOMS_CLASSES[l] || l || '';
const nomDeTaxon = (l) => NOMS_CLASSES[l] || NOMS_TAXONS[l] || l || '';

/* Les photos rangées dans une case : les siennes, puis celles des amis.
 *
 * Le serveur les envoyait depuis toujours — `captures` et `chez_les_amis` —
 * et le site ne les lisait pas. La fiche d'une espèce n'affichait donc aucune
 * photo, pas même les vôtres : on ouvrait une case pour voir ce qu'on y avait
 * mis, et on tombait sur du texte.
 *
 * C'est là que la case prend son intérêt : deux personnes qui ont trouvé la
 * même bête voient leurs clichés côte à côte. */
function photosDeCase(f) {
  const miennes = f.captures || [];
  const amies = f.chez_les_amis || [];
  if (!miennes.length && !amies.length) return '';

  // Chez un ami, l'avatar prime sur le nom : c'est ce qu'on reconnaît d'un
  // coup d'oeil sur une vignette de cent pixels. Chez soi, on n'affiche le
  // voile que s'il y a un titre — répéter son propre pseudo sur chaque photo
  // n'apprend rien.
  // La suite de navigation d'une case : ses photos et celles des amis, dans
  // l'ordre où elles s'affichent. Sans elle, glisser depuis une photo de case
  // retomberait sur la galerie, qui n'a rien à voir.
  const suite = JSON.stringify([...miennes, ...amies].map((c) => c.id));

  const tuile = (c, ami) => `
    <div class="tuile" onclick="ouvreVisionneuse(${c.id}, ${echappe(suite)})"
         title="${echappe(ami ? `${c.pseudo} — ${c.titre || ''}` : c.titre || '')}">
      <img src="${image(photoDePiece(c))}" alt="" loading="lazy">
      ${ami || c.titre ? `<div class="voile">
        ${ami ? avatar(c, 14) : ''}
        <span>${echappe(c.titre || (ami ? c.pseudo : ''))}</span>
      </div>` : ''}
    </div>`;

  return `
    <div class="photos-case">
      ${miennes.length ? `
        <h3 class="titre-section">${miennes.length > 1 ? 'Mes photos' : t('Ma photo')}</h3>
        <div class="mur serre">${miennes.map((c) => tuile(c, false)).join('')}</div>` : ''}
      ${amies.length ? `
        <h3 class="titre-section">${t('Chez les amis')}</h3>
        <div class="mur serre">${amies.map((c) => tuile(c, true)).join('')}</div>` : ''}
    </div>`;
}

/* Ce que montre la case : quelle photo, et sous quel cadrage.
 *
 * MegaDetector recadre parfois de travers — une patte, un bout de branche — et
 * la case hérite d'une découpe ratée. Il faut pouvoir reprendre la photo telle
 * qu'on l'a prise, sans changer le réglage de tout le dex.
 *
 * Trois modes, et le troisième n'est pas une redondance : sans « détourée »,
 * quelqu'un qui bascule son dex entier en photos entières ne pourrait plus
 * revenir en arrière sur une seule case.
 */
function reglageDeLaCase(f) {
  if (!f.decouvert) return '';
  const actuel = f.cadrage || 'auto';
  const mode = (cle, texte) => `
    <button class="puce ${actuel === cle ? 'actif' : ''}" style="--c:var(--accent)"
            onclick="changeCadrage(${f.id}, '${cle}')">${texte}</button>`;

  const choix = [...(f.captures || []), ...(f.chez_les_amis || [])];
  return `
    <div class="reglage-case">
      <h3 class="titre-section">${t('Ce que montre la case')}</h3>
      <div class="puces">
        ${mode('auto', t('Automatique'))}${mode('decoupe', t('Détourée'))}${mode('entier', t('Entière'))}
      </div>
      ${choix.length > 1 ? `
        <p class="doux" style="font-size:12px;margin:10px 0 4px">
          ${t('Quelle photo représente la case ?')}</p>
        <div class="rangee-prises">
          ${choix.map((c) => `
            <button class="prise" onclick="metVedette(${f.id}, ${c.id})"
                    title="${echappe(c.pseudo || 'Ma photo')}">
              <img src="${image(photoDePiece(c))}" alt="" loading="lazy">
              ${c.pseudo ? `<span class="doux">${echappe(c.pseudo)}</span>` : ''}
            </button>`).join('')}
        </div>` : ''}
    </div>`;
}

async function changeCadrage(caseId, mode) {
  try {
    await appel(`/dex/${caseId}/cadrage/${mode}`, { method: 'POST' });
    // La fiche porte le cadrage, et la grille du dex l'affiche : les deux sont
    // périmés. On relit la fiche, et on vide le dex pour qu'il se recharge.
    etat.fiche = await appel(`/dex/${caseId}`);
    Object.assign(etat, { trouvees: [], aTrouver: [] });
    dessine();
    if (etat.vue === 'dex') chargeDex();
  } catch (e) { signale(e.message, true); }
}

function vueFiche() {
  const f = etat.fiche;
  if (!f) return '';
  // Par ordre de préférence : sa propre photo détourée, sa photo, à défaut
  // l'illustration de Wikipédia, et en dernier ressort la silhouette.
  const propre = imageDeCase(f).chemin;
  const img = propre
    ? `<img class="grande" src="${image(propre)}" alt="">`
    : (f.image
        ? `<img class="grande" src="${image(f.image)}" alt="">`
        : (f.visuel
            ? `<img class="grande silhouette" src="${image(f.visuel)}" alt="">` : ''));
  return `
    <div class="feuille feuille-case" onclick="if(event.target===this)ferme('fiche')">
      <div class="corps">
        <div class="poignee"></div>
        ${img}
        <h2>${echappe(f.nom_fr || f.latin)}</h2>
        <div class="latin">${echappe(f.latin)}</div>
        <div class="pastilles">
          ${pastilleRarete(f.rarete, f.points)}
          ${f.regne ? pastilleRegne(f.regne) : ''}
          ${f.toxique ? `<span class="pastille toxique">${t('☠ Toxique')}</span>` : ''}
        </div>
        ${f.regne === 'champignon' ? avertissementChampignon() : ''}
        ${(f.alias || []).filter((a) => a !== f.latin).length ? `
          <!-- Les autres noms latins que la case regroupe : c'est ce qui
               explique qu'une recherche « Bos indicus » tombe sur la Vache. -->
          <p class="doux regroupe" style="margin-top:10px">
            <b>${t('Regroupe aussi')}</b> ${echappe((f.alias || [])
              .filter((a) => a !== f.latin).join(' · '))}</p>` : ''}
        ${f.ajoute_par_pseudo ? `
          <div class="bandeau-ajout">
            <span>👤</span>
            <p>${t('Ajouté par {0}. Cette espèce ne vient pas du référentiel : aucune analyse ne la proposera, on l\'y range à la main.', [echappe(f.ajoute_par_pseudo)])}</p>
          </div>` : ''}
        <p class="doux" style="margin-top:14px">
          ${echappe([f.classe, f.ordre, f.famille]
            .filter(Boolean).map(nomDeTaxon).join(' · '))}</p>
        ${f.decouvert
          ? `<p style="font-size:13.5px">${t('Trouvée {0} · {1} photo(s){2}', [quand(f.trouve_le), f.nb_captures, 
              f.vedette_de && etat.moi && f.vedette_de !== etat.moi.id
                ? ` ${t('· photo de {0}', [echappe(f.vedette_pseudo || '')])}` : ''])}</p>`
          : `<p class="doux" style="font-size:13.5px">${t('Pas encore trouvée.')}</p>`}
        ${f.approximation ? `<p class="doux" style="font-size:12px">
          ${t('Article le plus proche : {0}.', [echappe(f.approximation)])}</p>` : ''}
        ${f.resume ? `<p style="font-size:13.5px;line-height:1.55">${echappe(f.resume)}</p>` : ''}
        ${f.url ? `<p><a href="${echappe(f.url)}" target="_blank" rel="noopener">${t('Lire sur Wikipédia')}</a></p>` : ''}

        ${photosDeCase(f)}
        ${reglageDeLaCase(f)}
      </div>
    </div>`;
}

/* ───────────────────────────── photographier ───────────────────────────── */

function vueCapture() {
  const c = etat.captureEnCours;
  // Le champ de fichier n'a pas d'attribut `capture`, et c'est délibéré.
  //
  // Cet attribut demande à l'appareil photo de s'ouvrir directement. Sur iOS,
  // il ne fait pas que proposer la caméra en premier : il retire purement et
  // simplement « Photothèque » et « Choisir un fichier » du menu. On ne pouvait
  // plus envoyer une photo prise la veille, ni celle reçue par message — la
  // moitié des usages. Sans lui, le menu propose les trois, caméra comprise.
  if (!c && etat.preparation) return `
    <div class="centre" style="padding-top:24px">${vuePreparation()}</div>`;
  return `
    <div class="centre" style="padding-top:24px">
      ${c ? carteAnalyse(c) : `
        <div class="depot">
          <label class="zone">
            <input type="file" accept="image/*"
                   onchange="preparePhoto(this)" hidden>
            <svg viewBox="0 0 24 24" width="42" height="42" fill="currentColor">
              <path d="M12 15.2a3.2 3.2 0 100-6.4 3.2 3.2 0 000 6.4zM9 3L7.2 5H4a2 2 0 00-2 2v11a2 2 0 002 2h16a2 2 0 002-2V7a2 2 0 00-2-2h-3.2L15 3H9z"/>
            </svg>
            <b>${t('Prendre une photo')}</b>
            <span class="doux">${t('ou choisir une image')}</span>
          </label>
          <div class="puces regnes-capture" style="margin-top:14px">
            ${REGNES_APP.map((r) => `
              <button class="puce ${(etat.regne || 'animal') === r.cle ? 'actif' : ''}"
                      style="--c:${r.couleur}"
                      onclick="filtre('regne','${r.cle}')">${r.emoji} ${r.nom}</button>`).join('')}
          </div>
          <p class="doux" style="text-align:center;font-size:12.5px;margin-top:10px">
            ${t('Choisis le règne avant : c\'est lui qui décide du moteur d\'analyse.')}
          </p>
          <!-- L'avertissement se lit avant de photographier : après le
               verdict, on a déjà décidé ce qu'on voulait entendre. -->
          ${(etat.regne || 'animal') === 'champignon' ? avertissementChampignon() : ''}
        </div>`}
      ${enAttenteHTML()}
    </div>`;
}

/* Les photos qu'aucune espèce ne réclame.
 *
 * Elles n'apparaissent ni dans la galerie ni sur la carte, et le serveur les
 * efface au bout de quelques jours. Les montrer ici est la seule chance qu'a
 * le joueur de les rattraper avant la purge — les compter ne suffisait pas. */
function enAttenteHTML() {
  if (!etat.enAttente.length) return '';
  const tri = etat.aTrancherChoisies;
  const enTri = etat.aTrancherModeTri;
  return `
    <div class="tri-attente">
      <div class="rangee-titre">
        <h3 class="titre" style="margin-left:0">${t('À trancher')}</h3>
        <button class="lien" onclick="${enTri ? 'sortDuTri()' : 'entreDansLeTri()'}">
          ${enTri ? 'Terminer' : t('Sélectionner')}</button>
      </div>
      <p class="doux" style="font-size:12.5px;margin-top:-4px">
        ${t('Sans espèce, ces photos seront effacées dans {0} jour(s).', [etat.joursAvantPurge])}</p>
      ${enTri ? `
        <div class="barre-selection">
          <button class="outil" onclick="sortDuTri()" aria-label="${t('Annuler')}">
            <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
              <path d="M19 6.4L17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19
                       12 13.4 17.6 19 19 17.6 13.4 12z"/></svg></button>
          <b>${t('{0} sélectionnée{1}', [tri.size, tri.size > 1 ? 's' : ''])}</b>
          <button class="secondaire" onclick="toutTrancher()">${t('Tout')}</button>
          <button class="secondaire danger" ${tri.size ? '' : 'disabled'}
                  onclick="supprimeLesTranchees()">${t('Supprimer')}</button>
        </div>` : ''}
      ${etat.enAttente.map((c) => {
        const prise = tri.has(c.capture_id);
        return `
        <div class="ligne ${prise ? 'cochee' : ''}" style="padding-left:0;padding-right:0"
             onclick="${enTri ? `basculeTri(${c.capture_id})` : `reprend(${c.capture_id})`}">
          ${enTri ? `<span class="coche">${prise ? '●' : '○'}</span>` : ''}
          <img class="minia" src="${image(c.vignette)}" alt="">
          <span class="texte"><b>${echappe(c.verdict)}</b>
            <span class="doux">${quand(c.cree_le)}</span></span>
          <span class="doux">${enTri ? '' : '›'}</span>
        </div>`;
      }).join('')}
    </div>`;
}

/* Le tri des photos sans espèce.
 *
 * Une photo que le moteur n'a pas su nommer et qu'on ne saura pas nommer non
 * plus n'avait aucune sortie : ni rangeable ni jetable, elle occupait la base
 * jusqu'à la purge. D'où ce mode, calqué sur celui de la galerie — même barre,
 * même coche, mêmes gestes — plutôt qu'un troisième vocabulaire à apprendre.
 *
 * Le mode ne se referme pas tout seul quand la sélection retombe à zéro :
 * décocher sa dernière photo ferait disparaître la barre sous le doigt, et il
 * faudrait rouvrir le mode pour continuer. On sort par « Terminer ». */
function entreDansLeTri() { etat.aTrancherModeTri = true; dessine(); }

function sortDuTri() {
  etat.aTrancherModeTri = false;
  etat.aTrancherChoisies.clear();
  dessine();
}

function basculeTri(id) {
  if (etat.aTrancherChoisies.has(id)) etat.aTrancherChoisies.delete(id);
  else etat.aTrancherChoisies.add(id);
  dessine();
}

function toutTrancher() {
  const deja = etat.enAttente.length === etat.aTrancherChoisies.size;
  etat.aTrancherChoisies.clear();
  // Le même bouton coche tout puis décoche tout : sans cela, « Tout » n'a plus
  // aucun effet une fois pressé et il faut décocher les photos une par une.
  if (!deja) etat.enAttente.forEach((c) => etat.aTrancherChoisies.add(c.capture_id));
  dessine();
}

/* Jeter pour de bon : la ligne en base et les fichiers image.
 *
 * On demande confirmation parce que rien ne rattrape le geste — ni corbeille
 * ni annulation. Le serveur ne supprime que ce qui est sans espèce, donc une
 * découverte ne peut pas partir avec ; ça ne rend pas la perte des photos
 * moins définitive pour autant. */
async function supprimeLesTranchees() {
  const lot = [...etat.aTrancherChoisies];
  if (!lot.length) return;
  if (!confirm(`${t('Supprimer {0} photo(s) ?\\n\\n', [lot.length])}`
               + t('Les images et leurs données partent définitivement.'))) return;
  try {
    const r = await appel('/captures/non-identifiees/suppression',
                          { method: 'POST', body: { ids: lot } });
    sortDuTri();
    signale(`${t('{0} photo(s) supprimée(s).', [r.supprimees])}`);
    chargeEnAttente();
    chargeResume();
  } catch (e) { signale(e.message, true); }
}

function carteAnalyse(c) {
  if (c.etat === 'attente' || c.etat === 'analyse') {
    return `
      <div class="analyse">
        <div class="scene-capture">
          <img class="grande" src="${image(c.vignette)}" alt="">
          ${reglage('lancer', true)
            ? `<canvas data-role="sphere" data-capture="${c.id}"></canvas>`
            : ''}
        </div>
        <p class="doux" style="text-align:center;font-size:13px">
          ${t('Analyse en cours…{0}', [c.position_file > 1
            ? `<br>${t('{0} photo(s) dans la file.', [c.position_file])}` : ''])}</p>
      </div>`;
  }
  const pistes = (c.top || []).map((t) => `
    <div class="piste ${t.case_id ? '' : 'morte'}"
         ${t.case_id ? `data-appui-long="${t.case_id}" data-appui-role="apercu"
         data-appui-donnees="${apostrophes({ ...t, nom: t.nom_fr || t.latin,
                                             image: t.image })}"` : ''}>
      <!-- La vignette regarde la piste de près, le reste l'adopte : c'est le
           geste qui manquait, jusque-là il fallait choisir l'espèce pour la
           voir, donc se tromper volontairement pour comparer. -->
      <span class="apercu-espece" onclick="ouvreApercu(${t.case_id}, ${apostrophes({
        ...t, nom: t.nom_fr || t.latin, image: t.image })})">
        ${(() => {
          const illu = t.image || etat.illustrations[t.case_id];
          return illu ? `<img class="pleine" src="${image(illu)}" alt="">`
            : (t.visuel ? silhouetteHTML(t.visuel) : '<span class="rond"></span>');
        })()}
      </span>
      <span class="texte" onclick="choisitEspece(${c.id}, ${t.case_id})">
        <b>${echappe(t.nom_fr || t.latin)}${t.toxique
          ? ` <i class="marque-toxique">${t('TOXIQUE')}</i>` : ''}</b>
        <span class="doux">${echappe(t.latin)}</span>
      </span>
      <span class="proba">${Math.round((t.proba || 0) * 100)} %</span>
    </div>`).join('');

  // Trois issues, trois discours. « Indéterminé » avec des pistes à 30 % n'est
  // pas un échec : c'est une question posée au joueur.
  const entete = c.case_id
    ? `<h2 style="margin:12px 0 2px">${echappe(c.case?.nom_fr || c.verdict)}</h2>
       <p class="doux" style="margin:0 0 12px">${echappe(c.case?.latin || c.latin || '')}
         ${c.corrigee ? t('· choisie par toi')
           : ` ${t('· {0} % de confiance', [Math.round((c.confiance || 0) * 100)])}`}</p>`
    : `<h2 style="margin:12px 0 2px">${echappe(c.verdict || 'Indéterminé')}</h2>
       <p class="doux" style="margin:0 0 12px">
         ${pistes ? t('Choisis toi-même dans la liste.')
                  : t('Rien de reconnaissable sur cette photo.')}</p>`;

  const champignon = c.regne === 'champignon' || c.case?.regne === 'champignon'
    || (c.top || []).some((x) => x.regne === 'champignon');
  return `
    <div class="analyse">
      <img class="grande" src="${image(photoDePiece(c))}" alt="">
      ${champignon ? avertissementChampignon() : ''}
      ${entete}
      ${quandEtOu(c)}
      ${avecQui(c)}
      ${c.note ? `<p class="doux" style="font-size:12.5px">${echappe(c.note)}</p>` : ''}
      ${pistes ? `<p style="font-size:12.5px;font-weight:700;margin:14px 0 6px">
        ${c.case_id ? t('Ce n\'est pas ça ? Choisis :') : t('Les pistes du moteur :')}
        </p>${pistes}` : ''}
      <!-- Le détourage reste offert même quand l'espèce est trouvée. Il était
           réservé aux échecs, si bien qu'une fois la bête reconnue on ne
           pouvait plus la détourer — or c'est justement là qu'on y tient, pour
           que la vignette du dex montre l'animal et non la branche. -->
      <button class="secondaire" style="width:100%;margin-top:14px"
              onclick="ouvreEditeur(${c.id})">
        ${c.case_id ? t('✂ Détourer') : t('✂ Retoucher et réessayer')}</button>
      <div style="display:flex;gap:10px;margin-top:14px">
        <button class="secondaire" style="flex:1"
                onclick="ouvreChoixEspece('${echappe(c.verdict || '')}')">
          ${c.case_id ? t('Ce n\'est pas ça') : t('Choisir l\'espèce')}</button>
        ${c.case_id ? `<button class="secondaire" style="flex:1"
          onclick="choisitEspece(${c.id}, null)">${t('Détacher')}</button>` : ''}
      </div>
      ${c.case_id ? `
        <button class="discret" style="width:100%;margin-top:6px"
                onclick="demandeRelache(etat.captureEnCours)">${t('🕊 Relâcher')}</button>` : ''}
      <!-- Poser le lieu depuis ici, sans attendre la galerie : c'est le moment
           où l'on se souvient d'où vient la photo. L'écran porte déjà une carte
           et une recherche d'adresse ; il n'était simplement joignable que
           depuis la galerie, la visionneuse et « Mes photos ». -->
      <button class="secondaire" style="width:100%;margin-top:10px"
              onclick="situeLaCapture()">
        ${t('📍 Date et lieu')}</button>
      <button class="principal" style="margin-top:12px" onclick="nouvellePhoto()">
        ${t('Photographier autre chose')}</button>
    </div>`;
}

/* Qui d'autre a vu la bête.
 *
 * Une photo prise à deux compte pour deux : la case et les points tombent dans
 * les deux dex, sans que le fichier parte deux fois sur le serveur. */
function avecQui(c) {
  const gens = c.participants || [];
  const mienne = etat.moi && c.utilisateur === etat.moi.id;
  // Sur la photo d'un ami, on affiche qui était là mais on ne touche à rien :
  // c'est à l'auteur de dire qui l'accompagnait.
  return `
    <div class="avec-qui ${mienne ? 'cliquable' : ''}"
         ${mienne ? `onclick="ouvreIdentification(${c.id})"` : ''}>
      <span class="pictogramme">👥</span>
      <span class="texte">
        ${gens.length
          ? `<b>${t('Avec {0}', [gens.map((g) => echappe(g.pseudo)).join(', ')])}</b>`
          : `<span class="doux">${mienne ? "J'étais avec…" : t('Photo prise seul')}</span>`}
      </span>
      ${gens.slice(0, 4).map((g) => avatar(g, 22)).join('')}
      ${mienne ? '<span class="doux">›</span>' : ''}
    </div>`;
}

/* Le choix des amis présents.
 *
 * Une feuille plutôt qu'un écran : on y vient après coup, souvent juste pour
 * cocher une case, et perdre la photo de vue pour ça serait dommage. */
async function ouvreIdentification(captureId) {
  try {
    const [amis, deja] = await Promise.all([
      appel('/amis?limite=200'),
      appel(`/captures/${captureId}/participants`),
    ]);
    etat.identification = {
      captureId,
      amis: amis.amis || [],
      choisis: new Set((deja.participants || []).map((p) => p.id)),
      initiaux: new Set((deja.participants || []).map((p) => p.id)),
      envoi: false,
    };
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* Cocher un ami sur la photo qu'on identifie.
 *
 * Portait le même nom que la bascule des filtres de galerie, déclarée plus
 * bas : celle-ci l'écrasait, et cocher un ami sur une photo touchait en
 * réalité le filtre de la galerie. Sans erreur, comme toujours avec deux
 * fonctions du même nom.
 */
function basculeAmiIdentifie(id) {
  const i = etat.identification;
  if (!i) return;
  if (i.choisis.has(id)) i.choisis.delete(id); else i.choisis.add(id);
  dessine();
}

/* On enregistre la différence, pas l'état complet : le serveur a une route
 * pour ajouter et une pour retirer, et envoyer la liste entière ferait qu'une
 * feuille laissée ouverte effacerait les ajouts faits ailleurs entre-temps. */
async function enregistreIdentification() {
  const i = etat.identification;
  if (!i) return;
  const ajouts = [...i.choisis].filter((x) => !i.initiaux.has(x));
  const retraits = [...i.initiaux].filter((x) => !i.choisis.has(x));
  if (!ajouts.length && !retraits.length) { ferme('identification'); return; }
  i.envoi = true; dessine();
  try {
    for (const id of retraits) {
      await appel(`/captures/${i.captureId}/participants/${id}`, { method: 'DELETE' });
    }
    if (ajouts.length) {
      const pseudos = i.amis.filter((a) => ajouts.includes(a.id)).map((a) => a.pseudo);
      // Une requête par photo : le serveur n'a pas de route de lot, et lui en
      // ajouter une pour économiser quelques allers-retours sur une poignée de
      // photos serait payer cher une optimisation qu'on ne mesurerait pas.
      for (const capture of [i.captureId, ...(i.aussi || [])]) {
        await appel(`/captures/${capture}/participants`,
                    { method: 'POST', body: { pseudos } });
      }
    }
    const capture = await appel(`/captures/${i.captureId}`);
    if (etat.captureEnCours?.id === capture.id) etat.captureEnCours = capture;
    if (etat.visionneuse?.id === capture.id) etat.visionneuse = capture;
    const combien = 1 + (i.aussi?.length || 0);
    etat.identification = null;
    etat.choisies.clear();
    signale(`${t('{0} photo{1} partagée{2}.', [combien, combien > 1 ? 's' : '', 
      combien > 1 ? 's' : ''])}`);
  } catch (e) {
    i.envoi = false;
    signale(e.message, true);
  }
}

function vueIdentification() {
  const i = etat.identification;
  if (!i) return '';
  return `
    <div class="feuille" onclick="if(event.target===this)ferme('identification')">
      <div class="corps">
        <div class="poignee"></div>
        <h2>${t('Qui était avec toi ?{0}', [i.aussi?.length
          ? ` <span class="doux">${t('({0} photos)', [i.aussi.length + 1])}</span>` : ''])}</h2>
        <p class="doux" style="font-size:12.5px;line-height:1.35">
          ${t('La photo comptera dans leur dex aussi, avec les points. Elle ne sera pas envoyée en double : un seul cliché, plusieurs collections.')}</p>
        ${i.amis.length ? i.amis.map((a) => `
          <label class="ligne" style="cursor:pointer">
            ${avatar(a)}
            <span class="texte"><b>${echappe(a.pseudo)}</b>
              <span class="doux">${t('{0} espèce(s)', [a.cases ?? 0])}</span></span>
            <input type="checkbox" ${i.choisis.has(a.id) ? 'checked' : ''}
                   onchange="basculeAmiIdentifie(${a.id})">
          </label>`).join('')
          : `<div class="vide">${t('Tu n\'as pas encore d\'amis.')}</div>`}
        <button class="principal" style="margin-top:16px"
                ${i.envoi ? 'disabled' : ''}
                onclick="enregistreIdentification()">
          ${i.envoi ? 'Enregistrement…' : t('Terminé')}</button>
      </div>
    </div>`;
}

/* Une date ou un lieu n'est sûr que s'il vient de la photo ou du joueur. */
const SUR = (source) => source === 'exif' || source === 'manuel'
                        || source === 'appareil';

/* Le rappel de quand et où, avec de quoi rectifier.
 *
 * Une photo tirée de la pellicule arrive souvent sans EXIF : la date devient
 * celle de l'envoi et le lieu celui d'où l'on se trouvait. Plutôt que de
 * laisser croire à une donnée juste, on le dit et on ouvre la porte à la
 * correction. */
function quandEtOu(c) {
  const douteux = !SUR(c.source_heure) || !SUR(c.source_position);
  const situee = c.lat != null && c.lon != null;
  const ou = c.lieu || (situee
    ? `${c.lat.toFixed(4)}, ${c.lon.toFixed(4)}` : t('lieu inconnu'));
  const quand = (c.prise_le || c.cree_le || '').slice(0, 16).replace(' ', ' à ');

  return `
    ${situee ? `<div class="timbre" id="timbre-${c.id}"
                     data-lat="${c.lat}" data-lon="${c.lon}"
                     data-doute="${douteux ? 1 : 0}"></div>` : ''}
    <div class="quand-ou ${douteux ? 'doute' : ''}">
      <span class="pictogramme">${douteux ? '?' : '🕑'}</span>
      <span class="texte">
        <b>${echappe(quand)}</b>
        <span class="doux">${echappe(ou)}</span>
        ${douteux ? `<span class="alerte-douce">
          ${t('Date et lieu de l\'envoi, pas de la prise de vue.')}</span>` : ''}
      </span>
    </div>
    ${douteux ? `
      <button class="secondaire" style="width:100%;margin-top:8px"
              onclick="iciMaintenant(${c.id})">
        ${t('📍 Je l\'ai vue ici, à l\'instant')}</button>` : ''}`;
}

/* Pose la position du navigateur et l'heure courante sur la capture.
 *
 * Les deux passent en « manuel » côté serveur : le joueur affirme, il ne subit
 * plus une valeur devinée. La photo sort donc de la liste des clichés à situer
 * et l'avertissement disparaît. */
async function iciMaintenant(id) {
  try {
    const p = await new Promise((ok, non) => {
      if (!navigator.geolocation) return non(new Error(t('Localisation indisponible.')));
      navigator.geolocation.getCurrentPosition(ok, () =>
        non(new Error(t('Position refusée. Autorise la localisation.'))),
        { timeout: 8000, enableHighAccuracy: true });
    });
    const c = await appel(`/captures/${id}/lieu`, {
      method: 'PATCH',
      body: {
        lat: p.coords.latitude,
        lon: p.coords.longitude,
        // Le serveur attend « AAAA-MM-JJ HH:MM:SS » en UTC, comme ses propres
        // dates : lui envoyer l'heure locale décalerait la photo d'une ou deux
        // heures dans la galerie.
        prise_le: new Date().toISOString().slice(0, 19).replace('T', ' '),
      },
    });
    if (etat.captureEnCours?.id === id) etat.captureEnCours = c;
    signale(t('Date et lieu enregistrés.'));
  } catch (e) { signale(e.message, true); }
}

/* ═════════════════════ l'aperçu d'une espèce proposée ═══════════════════ */

/* Devant « Pica pica » et « Corvus corone », une vignette de 46 pixels ne
 * permet pas de trancher. Il fallait choisir l'espèce pour la voir, donc se
 * tromper volontairement pour comparer. Cet aperçu montre la photo en grand
 * et l'article Wikipédia, et ne valide rien tant qu'on ne le demande pas. */
async function ouvreApercu(caseId, source) {
  if (!caseId) return;
  const base = source || {};
  etat.apercu = { case_id: caseId, ...base, charge: true };
  dessine();
  try {
    const f = await appel(`/dex/${caseId}/fiche`);
    if (etat.apercu?.case_id !== caseId) return;      // on a refermé entre-temps
    if (f.trouvee) {
      etat.apercu = {
        ...etat.apercu,
        resume: f.resume || etat.apercu.resume,
        image: f.image || etat.apercu.image,
        url: f.url || '',
        approximation: f.approximation || '',
      };
    }
  } catch (_) {
    // Sans article, l'aperçu se contente du nom et de la silhouette.
  } finally {
    if (etat.apercu?.case_id === caseId) { etat.apercu.charge = false; dessine(); }
  }
}

function vueApercu() {
  const a = etat.apercu;
  if (!a) return '';
  return `
    <div class="voile-modale" onclick="if(event.target===this)ferme('apercu')">
      <div class="modale">
        ${a.image
          ? `<div class="photo-apercu"><img src="${image(a.image)}" alt=""></div>`
          : `<div class="photo-apercu vide">
               ${a.visuel ? silhouetteHTML(a.visuel) : '<span>?</span>'}</div>`}

        <!-- Le bandeau ne s'affiche que quand l'espèce est signalée. Un
             « non toxique » serait une promesse que personne ne peut tenir. -->
        ${a.toxique ? `<div class="bandeau-toxique">
          ${t('☠ ESPÈCE SIGNALÉE TOXIQUE')}</div>` : ''}

        <div class="dedans">
          <h2>${echappe(a.nom || a.nom_fr || a.latin)}</h2>
          ${a.latin && a.latin !== (a.nom || a.nom_fr)
            ? `<div class="latin">${echappe(a.latin)}</div>` : ''}
          <div class="pastilles">
            ${a.regne ? pastilleRegne(a.regne) : ''}
            ${a.rarete ? pastilleRarete(a.rarete, a.points) : ''}
            ${a.proba != null
              ? `<span class="pastille-neutre">${t('confiance {0} %', [
                  Math.round(a.proba * 100)])}</span>` : ''}
          </div>
          ${a.charge && !a.resume
            ? '<div class="tourne petit"><span></span></div>'
            : (a.resume
                ? `<p class="article">${echappe(a.resume)}</p>`
                : `<p class="doux" style="font-size:13px">
                     ${t('Pas d\'article Wikipédia pour cette espèce.')}</p>`)}
          ${a.approximation ? `<p class="doux" style="font-size:11.5px">
            ${t('Article le plus proche : {0}.', [echappe(a.approximation)])}</p>` : ''}
          ${a.url ? `<p class="doux" style="font-size:11px">${t('Source : Wikipédia')}</p>` : ''}
        </div>

        <div class="pied">
          <button class="discret" style="width:auto"
                  onclick="ferme('apercu')">${t('Fermer')}</button>
          <button class="principal" style="width:auto;min-height:44px;padding:11px 18px"
                  onclick="retientApercu()">${t('✓ C\'est celle-ci')}</button>
        </div>
      </div>
    </div>`;
}

/* Valider l'aperçu, c'est choisir l'espèce — pour la capture en cours si on
 * vient de l'analyse, sinon c'est qu'on regardait simplement une fiche. */
function retientApercu() {
  const a = etat.apercu;
  if (!a) return;
  etat.apercu = null;
  if (etat.captureEnCours) choisitEspece(etat.captureEnCours.id, a.case_id);
  else dessine();
}

/* ══════════════════════════ retoucher une photo ═══════════════════════════ */

/* Un éditeur écrit à la main plutôt qu'une bibliothèque.
 *
 * Le besoin est étroit — recadrer, pivoter, éclaircir, entourer — et les
 * bibliothèques du genre pèsent plusieurs centaines de kilo-octets pour
 * couvrir vingt fois ce périmètre. Le site entier en fait cent : lui greffer
 * un éditeur cinq fois plus gros que lui-même pour un écran qu'on ouvre
 * rarement serait un mauvais échange.
 *
 * Tout se joue sur un `<canvas>` : les réglages restent des paramètres tant
 * qu'on n'a pas validé, et l'image d'origine n'est touchée qu'au dernier
 * moment. On peut donc revenir en arrière sans perte, ce qu'une chaîne de
 * transformations appliquées au fur et à mesure interdirait. */

/* Les réglages en cours. `null` quand l'éditeur est fermé. */
function editeurNeuf(captureId, img) {
  return {
    captureId,
    img,
    rotation: 0,          // en quarts de tour
    luminosite: 100,      // en pourcentage
    contraste: 100,
    // Le recadrage, en fractions de l'image redressée : indépendant de la
    // taille d'affichage, donc juste quel que soit l'écran.
    coupe: { x: 0, y: 0, l: 1, h: 1 },
    traits: [],           // les annotations, en fractions elles aussi
    // Le tracé du lasso, en fractions de l'image redressée. Vide tant qu'on
    // n'a pas détouré : une liste vide vaut « pas de détourage », ce qui n'est
    // pas la même chose qu'un tracé qui n'entoure rien.
    lasso: [],
    dessine: false,
    outil: 'recadre',
    envoi: false,
  };
}

/* Ouvrir l'éditeur, sur une capture envoyée ou sur un fichier local.
 *
 * `source` sert au second cas : la photo choisie n'a pas encore quitté le
 * téléphone, et on veut pouvoir la redresser et détourer la bête *avant* de
 * la confier au moteur — c'est là que le détourage sert le plus, puisqu'il
 * change ce que le moteur regarde. Tout l'éditeur travaille déjà sur l'image
 * décodée et non sur l'identifiant : seule la validation diffère.
 */
async function ouvreEditeur(captureId, source = null) {
  try {
    // L'originale, pas la vignette : recadrer un carré de 512 pixels ne
    // laisserait plus assez de matière pour reconnaître quoi que ce soit.
    const img = new Image();
    img.src = source || image(`/captures/${captureId}/photo`);
    await img.decode();
    etat.editeur = editeurNeuf(captureId, img);
    etat.editeur.local = !captureId;
    dessine();
    peintEditeur();
  } catch (_) {
    signale(t('Photo illisible.'), true);
  }
}

/* Redessine la toile depuis l'image d'origine et les réglages courants. */
/* L'image seule, sans une trace du crayon.
 *
 * La toile de l'éditeur porte trois couches : la photo, les annotations
 * rouges, et le trait du lasso. C'est ce qu'il faut à l'écran — on doit voir
 * ce qu'on entoure — mais les deux exports lisaient cette même toile, si bien
 * que la photo enregistrée sortait barbouillée du trait qui avait servi à la
 * découper. On veut l'originale propre et la découpe, pas un dessin.
 *
 * Cette fonction refait donc la première couche seule, hors écran, avec la
 * même géométrie : rotation, borne de taille, luminosité et contraste.
 */
function toilePropre(e) {
  const quart = e.rotation % 4;
  const tourne = quart % 2 === 1;
  const lNat = tourne ? e.img.naturalHeight : e.img.naturalWidth;
  const hNat = tourne ? e.img.naturalWidth : e.img.naturalHeight;
  const cote = Math.max(lNat, hNat);
  const facteur = cote > 1600 ? 1600 / cote : 1;

  const t = document.createElement('canvas');
  t.width = Math.round(lNat * facteur);
  t.height = Math.round(hNat * facteur);
  const ctx = t.getContext('2d');
  ctx.filter = `brightness(${e.luminosite}%) contrast(${e.contraste}%)`;
  ctx.translate(t.width / 2, t.height / 2);
  ctx.rotate(quart * Math.PI / 2);
  const l = tourne ? t.height : t.width;
  const h = tourne ? t.width : t.height;
  ctx.drawImage(e.img, -l / 2, -h / 2, l, h);
  return t;
}

function peintEditeur() {
  const e = etat.editeur;
  const toile = document.getElementById('toile');
  if (!e || !toile) return;

  const quart = e.rotation % 4;
  const tourne = quart % 2 === 1;
  const lNat = tourne ? e.img.naturalHeight : e.img.naturalWidth;
  const hNat = tourne ? e.img.naturalWidth : e.img.naturalHeight;

  // On borne la toile : une photo de 12 mégapixels ferait ramer le pinceau
  // sur un téléphone, et le serveur réduit de toute façon à l'arrivée.
  const cote = Math.max(lNat, hNat);
  const facteur = cote > 1600 ? 1600 / cote : 1;
  toile.width = Math.round(lNat * facteur);
  toile.height = Math.round(hNat * facteur);

  const ctx = toile.getContext('2d');
  ctx.save();
  ctx.filter = `brightness(${e.luminosite}%) contrast(${e.contraste}%)`;
  ctx.translate(toile.width / 2, toile.height / 2);
  ctx.rotate(quart * Math.PI / 2);
  const l = tourne ? toile.height : toile.width;
  const h = tourne ? toile.width : toile.height;
  ctx.drawImage(e.img, -l / 2, -h / 2, l, h);
  ctx.restore();

  // Les annotations par-dessus, en coordonnées relatives.
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.strokeStyle = '#e05252';
  ctx.lineWidth = Math.max(3, toile.width * 0.006);
  for (const trait of e.traits) {
    ctx.beginPath();
    trait.forEach((p, i) => {
      const x = p[0] * toile.width;
      const y = p[1] * toile.height;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();
  }

  // Le lasso par-dessus tout le reste : c'est lui qui décide ce qui sera
  // gardé, il doit rester lisible quelles que soient les annotations.
  peintLasso(ctx, e, toile.width, toile.height);
}

/* Les coordonnées d'un geste, ramenées en fractions de la toile. */
function pointToile(ev) {
  const toile = document.getElementById('toile');
  const cadre = toile.getBoundingClientRect();
  const t = ev.touches?.[0] || ev;
  return [
    Math.min(1, Math.max(0, (t.clientX - cadre.left) / cadre.width)),
    Math.min(1, Math.max(0, (t.clientY - cadre.top) / cadre.height)),
  ];
}

function debuteGeste(ev) {
  const e = etat.editeur;
  if (!e) return;
  ev.preventDefault();
  const p = pointToile(ev);
  if (e.outil === 'lasso') {
    // Un nouveau geste repart de zéro : on ne recolle pas deux tracés bout à
    // bout, ce qui donnerait une forme dont personne ne comprend le contour.
    e.lasso = [{ x: p[0], y: p[1] }];
    e.dessine = true;
  } else if (e.outil === 'dessin') {
    e.traits.push([p]);
    e.dessine = true;
  } else {
    e.coupe = { x: p[0], y: p[1], l: 0, h: 0 };
    e.dessine = true;
    e.ancre = p;
  }
}

function suitGeste(ev) {
  const e = etat.editeur;
  if (!e?.dessine) return;
  ev.preventDefault();
  const p = pointToile(ev);
  if (e.outil === 'lasso') {
    e.lasso.push({ x: p[0], y: p[1] });
    peintEditeur();
  } else if (e.outil === 'dessin') {
    e.traits.at(-1).push(p);
    peintEditeur();
  } else {
    e.coupe = {
      x: Math.min(e.ancre[0], p[0]),
      y: Math.min(e.ancre[1], p[1]),
      l: Math.abs(p[0] - e.ancre[0]),
      h: Math.abs(p[1] - e.ancre[1]),
    };
    dessineCadreCoupe();
  }
}

function finitGeste() {
  const e = etat.editeur;
  if (!e) return;
  e.dessine = false;
  // Un recadrage trop petit vient d'un doigt qui a glissé, pas d'une
  // intention : on l'annule plutôt que de rendre l'image inutilisable.
  if (e.outil === 'recadre' && (e.coupe.l < 0.05 || e.coupe.h < 0.05)) {
    e.coupe = { x: 0, y: 0, l: 1, h: 1 };
    dessineCadreCoupe();
  }
  // Le lasso a besoin d'un rendu de plus à la fin du geste : c'est là que la
  // consigne passe d'« ouverte » à « fermée », et elle vit dans le HTML.
  if (e.outil === 'lasso') dessine();
}

/* Le rectangle de recadrage, posé par-dessus la toile. */
/* ------------------------------------------------------------------ lasso
 *
 * Le tracé au doigt ne se referme pas tout seul, et c'est le point.
 *
 * Une boucle refermée d'office donne toujours une forme, y compris quand le
 * doigt s'est arrêté à mi-chemin : on croit avoir détouré la bête et on a
 * découpé une tranche. On regarde donc si le doigt est revenu près de son
 * point de départ, et on le dit quand ce n'est pas le cas — sans empêcher de
 * valider, parce qu'une ligne droite entre les deux bouts est souvent ce que
 * le joueur voulait. */

const LASSO_MINIMUM = 8;

/* La boucle est-elle bouclée ?
 *
 * Deux dixièmes et demi de la diagonale de la boîte englobante. Réglé sur un
 * tracé à qui il manquait un vingt-quatrième de tour : à 0,18 il était déclaré
 * ouvert, ce qui est faux — le doigt était revenu. */
function lassoFerme(pts) {
  if (!pts || pts.length < LASSO_MINIMUM) return false;
  let xmin = 1; let ymin = 1; let xmax = 0; let ymax = 0;
  pts.forEach((p) => {
    xmin = Math.min(xmin, p.x); xmax = Math.max(xmax, p.x);
    ymin = Math.min(ymin, p.y); ymax = Math.max(ymax, p.y);
  });
  const l = xmax - xmin; const h = ymax - ymin;
  const diagonale = Math.sqrt(l * l + h * h);
  if (diagonale <= 0) return false;
  const a = pts[0]; const b = pts[pts.length - 1];
  const ecart = Math.hypot(b.x - a.x, b.y - a.y);
  return ecart / diagonale < 0.22;
}

/* Le chemin du tracé sur une toile donnée. `ferme` referme en ligne droite —
 * ce qu'on fait toujours pour découper, jamais pour dessiner l'aperçu. */
function cheminLasso(ctx, pts, l, h, ferme) {
  ctx.beginPath();
  pts.forEach((p, i) => {
    const x = p.x * l; const y = p.y * h;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  if (ferme) ctx.closePath();
}

/* Le tracé par-dessus la photo, dans l'éditeur.
 *
 * Ouvert, il est orange et pointillé entre les deux bouts : la couleur et le
 * trou disent ce qui manque mieux qu'un message. Fermé, on assombrit le
 * dehors, ce qui montre d'un coup d'œil ce qui sera gardé. */
function peintLasso(ctx, e, l, h) {
  const pts = e.lasso;
  if (pts.length < 2) return;
  const ferme = lassoFerme(pts);

  if (ferme) {
    ctx.save();
    cheminLasso(ctx, pts, l, h, true);
    ctx.globalCompositeOperation = 'source-over';
    // On peint le dehors : un rectangle plein moins la forme, obtenu par la
    // règle de remplissage « evenodd ».
    ctx.beginPath();
    ctx.rect(0, 0, l, h);
    pts.forEach((p, i) => {
      const x = p.x * l; const y = p.y * h;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.closePath();
    ctx.fillStyle = 'rgba(0,0,0,.45)';
    ctx.fill('evenodd');
    ctx.restore();
  }

  ctx.save();
  ctx.lineWidth = Math.max(2, l * 0.006);
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.strokeStyle = ferme ? '#0ea5a4' : '#e8a317';
  cheminLasso(ctx, pts, l, h, false);
  ctx.stroke();

  if (!ferme) {
    // Le raccourci qui sera pris à la validation, en pointillé : on montre ce
    // qui va se passer plutôt que de le laisser découvrir après coup.
    ctx.setLineDash([6, 6]);
    ctx.beginPath();
    ctx.moveTo(pts[pts.length - 1].x * l, pts[pts.length - 1].y * h);
    ctx.lineTo(pts[0].x * l, pts[0].y * h);
    ctx.stroke();
    ctx.setLineDash([]);
    [pts[0], pts[pts.length - 1]].forEach((p) => {
      ctx.beginPath();
      ctx.arc(p.x * l, p.y * h, ctx.lineWidth * 1.8, 0, Math.PI * 2);
      ctx.fillStyle = '#e8a317';
      ctx.fill();
    });
  }
  ctx.restore();
}

function consigneLasso(e) {
  if (e.lasso.length < LASSO_MINIMUM) {
    return { mot: t('Entoure la bête avec ton doigt, et reviens à ton point de départ.'), ok: null };
  }
  return lassoFerme(e.lasso)
    ? { mot: t('Forme fermée.'), ok: true }
    : { mot: t('Forme ouverte : elle sera refermée en ligne droite.'), ok: false };
}

function effaceLasso() {
  if (!etat.editeur) return;
  etat.editeur.lasso = [];
  dessine();
}

/* Envoyer le détourage.
 *
 * On ne touche à rien d'autre : ni l'espèce, ni la photo d'origine, ni la
 * date. C'est la vignette de la grille qu'on remplace, et le serveur repasse
 * son modèle de détourage sur le tracé pour en affiner le bord. */
async function envoieLasso() {
  const e = etat.editeur;
  if (!e || e.envoi) return;
  if (e.lasso.length < LASSO_MINIMUM) {
    signale(t('Entoure d\'abord la bête.'), true);
    return;
  }
  e.envoi = true; dessine(); peintEditeur();
  try {
    // L'image sans le trait ni les annotations : c'est le tracé qui découpe,
    // il n'a pas à figurer dans le résultat.
    const source = toilePropre(e);
    const l = source.width; const h = source.height;

    // La découpe part en PNG : c'est le seul format courant qui garde la
    // transparence, et c'est elle qui porte le détourage.
    const sortie = document.createElement('canvas');
    sortie.width = l; sortie.height = h;
    const ctx = sortie.getContext('2d');
    cheminLasso(ctx, e.lasso, l, h, true);
    ctx.clip();
    ctx.drawImage(source, 0, 0);

    const blob = await new Promise((ok) => sortie.toBlob(ok, 'image/png'));

    // Photo pas encore envoyée : la découpe voyage avec elle. `POST /captures`
    // accepte déjà un champ `decoupe` — le tracé remplace alors le détourage
    // automatique, qui garde souvent la branche ou coupe une patte.
    if (e.local) {
      if (etat.preparation) etat.preparation.decoupe = blob;
      etat.editeur = null;
      signale(t('Détourage prêt. Lance l\'analyse quand tu veux.'));
      dessine();
      return;
    }

    const forme = new FormData();
    forme.append('decoupe', blob, 'decoupe.png');
    await appel(`/captures/${e.captureId}/decoupe`, { method: 'PUT', body: forme });
    etat.editeur = null;
    signale(t('Détourage enregistré.'));
    if (etat.vue === 'galerie') chargeGalerie(true);
    // La visionneuse ouverte montre encore l'ancienne découpe : on la relit.
    if (etat.visionneuse?.id === e.captureId) {
      try { etat.visionneuse = await appel(`/captures/${e.captureId}`); }
      catch (_) { /* la photo a pu disparaître entre-temps */ }
    }
    dessine();
  } catch (err) {
    e.envoi = false;
    signale(err.message, true);
    dessine();
  }
}

function dessineCadreCoupe() {
  const e = etat.editeur;
  const cadre = document.getElementById('coupe');
  if (!e || !cadre) return;
  const c = e.coupe;
  const entier = c.l >= 0.999 && c.h >= 0.999;
  cadre.style.display = entier ? 'none' : 'block';
  cadre.style.left = `${c.x * 100}%`;
  cadre.style.top = `${c.y * 100}%`;
  cadre.style.width = `${c.l * 100}%`;
  cadre.style.height = `${c.h * 100}%`;
}

function regleEditeur(champ, valeur) {
  if (!etat.editeur) return;
  etat.editeur[champ] = Number(valeur);
  peintEditeur();
}

function outilEditeur(nom) {
  if (!etat.editeur) return;
  etat.editeur.outil = nom;
  dessine();
  peintEditeur();
  dessineCadreCoupe();
}

function pivoteEditeur() {
  const e = etat.editeur;
  if (!e) return;
  e.rotation = (e.rotation + 1) % 4;
  // Le recadrage n'a plus de sens dans le nouveau repère : le garder
  // découperait un rectangle au hasard.
  e.coupe = { x: 0, y: 0, l: 1, h: 1 };
  peintEditeur();
  dessineCadreCoupe();
}

function annuleTrait() {
  const e = etat.editeur;
  if (!e?.traits.length) return;
  e.traits.pop();
  peintEditeur();
}

function reinitialiseEditeur() {
  const e = etat.editeur;
  if (!e) return;
  Object.assign(e, {
    rotation: 0, luminosite: 100, contraste: 100,
    coupe: { x: 0, y: 0, l: 1, h: 1 }, traits: [],
  });
  peintEditeur();
  dessineCadreCoupe();
}

/* Applique le recadrage et renvoie la photo au moteur. */
async function envoieRetouche() {
  const e = etat.editeur;
  if (!e || e.envoi) return;
  e.envoi = true;
  dessine();
  peintEditeur();
  dessineCadreCoupe();
  try {
    // L'image propre, pas la toile de l'écran : la photo qu'on garde ne doit
    // porter ni les annotations rouges ni le trait du lasso.
    const source = toilePropre(e);
    const c = e.coupe;
    const x = Math.round(c.x * source.width);
    const y = Math.round(c.y * source.height);
    const l = Math.max(1, Math.round(c.l * source.width));
    const h = Math.max(1, Math.round(c.h * source.height));

    const sortie = document.createElement('canvas');
    sortie.width = l;
    sortie.height = h;
    sortie.getContext('2d').drawImage(source, x, y, l, h, 0, 0, l, h);

    const blob = await new Promise((ok) =>
      sortie.toBlob(ok, 'image/jpeg', 0.92));

    // Photo pas encore envoyée : la retouche remplace le fichier en attente,
    // et on retourne à l'écran de préparation. Rien ne part au serveur — il
    // n'y a pas encore de capture à reprendre.
    if (e.local) {
      const p = etat.preparation;
      if (p) {
        URL.revokeObjectURL(p.apercu);
        p.fichier = new File([blob], 'retouche.jpg', { type: 'image/jpeg' });
        p.apercu = URL.createObjectURL(p.fichier);
        // Le tracé portait sur l'image d'avant : le garder recadrerait de
        // travers. On repart proprement.
        p.decoupe = null;
      }
      etat.editeur = null;
      signale(t('Retouche appliquée.'));
      dessine();
      return;
    }

    const forme = new FormData();
    forme.append('photo', blob, 'retouche.jpg');
    const capture = await appel(`/captures/${e.captureId}/reprise`,
                                { method: 'POST', body: forme });
    etat.editeur = null;
    etat.captureEnCours = capture;
    etat.vue = 'capture';
    dessine();
    // La photo repart en file : on reprend le suivi comme après un envoi.
    suitAnalyse(capture.id);
  } catch (err) {
    e.envoi = false;
    signale(err.message, true);
    dessine();
    peintEditeur();
  }
}

function vueEditeur() {
  const e = etat.editeur;
  if (!e) return '';
  return `
    <div class="plein sombre editeur">
      <header class="sur-sombre">
        <button class="retour" onclick="ferme('editeur')" aria-label="${t('Fermer')}">
          <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
            <path d="M19 6.4L17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19
                     12 13.4 17.6 19 19 17.6 13.4 12z"/></svg></button>
        <h1>${t('Retoucher')}</h1>
        <button class="outil" onclick="reinitialiseEditeur()" title="${t('Tout remettre')}">
          <svg viewBox="0 0 24 24" width="21" height="21" fill="currentColor">
            <path d="M12 5V1L7 6l5 5V7a6 6 0 11-6 6H4a8 8 0 108-8z"/></svg>
        </button>
      </header>

      <div class="scene">
        <div class="cadre-toile">
          <canvas id="toile"
                  onmousedown="debuteGeste(event)" onmousemove="suitGeste(event)"
                  onmouseup="finitGeste()" onmouseleave="finitGeste()"
                  ontouchstart="debuteGeste(event)" ontouchmove="suitGeste(event)"
                  ontouchend="finitGeste()"></canvas>
          <div id="coupe" class="cadre-coupe"></div>
        </div>
      </div>

      <div class="outils">
        <div class="segments">
          ${[['recadre', t('Recadrer')], ['lasso', t('Détourer')],
             ['dessin', t('Entourer')], ['lumiere', t('Lumière')]].map(([k, n]) => `
            <button class="${e.outil === k ? 'actif' : ''}"
                    onclick="outilEditeur('${k}')">${n}</button>`).join('')}
        </div>

        ${e.outil === 'lumiere' ? `
          <label class="glissiere">
            <span>${t('Luminosité')}</span>
            <input type="range" min="40" max="200" value="${e.luminosite}"
                   oninput="regleEditeur('luminosite', this.value)">
          </label>
          <label class="glissiere">
            <span>${t('Contraste')}</span>
            <input type="range" min="40" max="220" value="${e.contraste}"
                   oninput="regleEditeur('contraste', this.value)">
          </label>` : ''}

        ${e.outil === 'recadre' ? `
          <p class="doux aide">${t('Glisse sur la photo pour choisir la zone. Un petit rectangle annule le recadrage.')}</p>
          <button class="secondaire" onclick="pivoteEditeur()">${t('↻ Pivoter')}</button>` : ''}

        ${e.outil === 'lasso' ? `
          <p class="consigne ${consigneLasso(e).ok === true ? 'bonne'
            : consigneLasso(e).ok === false ? 'tiede' : ''}">
            ${consigneLasso(e).mot}</p>
          <div class="rangee">
            <button onclick="effaceLasso()" ${e.lasso.length ? '' : 'disabled'}>${t('Effacer')}</button>
            <button class="primaire" onclick="envoieLasso()"
                    ${e.lasso.length >= 8 && !e.envoi ? '' : 'disabled'}>
              ${t('Détourer')}</button>
          </div>` : ''}

        ${e.outil === 'dessin' ? `
          <p class="doux aide">${t('Trace au doigt pour entourer la bête.')}</p>
          <button class="secondaire" onclick="annuleTrait()"
                  ${e.traits.length ? '' : 'disabled'}>${t('Effacer le dernier trait')}</button>` : ''}

        <button class="principal" style="margin-top:12px"
                ${e.envoi ? 'disabled' : ''} onclick="envoieRetouche()">
          ${e.envoi ? 'Envoi…' : t('Réanalyser cette photo')}</button>
      </div>
    </div>`;
}

/* ═══════════════════════ chercher l'espèce soi-même ══════════════════════ */

/* Sert quand le moteur s'est trompé, ou n'a rien reconnu du tout. La recherche
 * porte aussi sur les synonymes : taper « Bos indicus » ramène la case Vache,
 * puisque c'est là que le zébu atterrit. */
function ouvreChoixEspece(piste) {
  etat.choixEspece = { texte: piste || '', resultats: [], charge: true };
  dessine();
  chercheEspece(piste || '', true);
}

let minuteurEspece;
function chercheEspece(texte, tout_de_suite = false) {
  if (!etat.choixEspece) return;
  etat.choixEspece.texte = texte;
  clearTimeout(minuteurEspece);
  const lance = async () => {
    if (!etat.choixEspece) return;
    etat.choixEspece.charge = true;
    dessine();
    try {
      const p = new URLSearchParams({ limite: 50 });
      // Sans recherche, on propose les espèces les plus communes : c'est le
      // meilleur point de départ quand on ne sait pas quoi taper.
      if (texte.trim()) p.set('q', texte.trim());
      const d = await appel(`/dex?${p}`);
      if (!etat.choixEspece) return;
      etat.choixEspece.resultats = d.cases || [];
      etat.choixEspece.erreur = null;
      dessine();
      chargeApercus();
    } catch (e) {
      if (etat.choixEspece) etat.choixEspece.erreur = e.message;
    } finally {
      if (etat.choixEspece) { etat.choixEspece.charge = false; dessine(); }
    }
  };
  if (tout_de_suite) lance(); else minuteurEspece = setTimeout(lance, 350);
}

/* Les illustrations Wikipédia des premiers résultats.
 *
 * Seulement les premiers : ce sont ceux qu'on voit, et chaque espèce inconnue
 * coûte un aller-retour vers Wikipédia côté serveur. Elles arrivent après la
 * liste — la recherche ne doit pas les attendre. */
async function chargeApercus() {
  const c = etat.choixEspece;
  if (c) await chargeApercusDe(c.resultats.map((x) => x.id));
}

/* Les illustrations de n'importe quelle liste de cases.
 *
 * C'était réservé à la recherche, et la liste des pistes — celle qu'on regarde
 * quand le moteur hésite — restait en silhouettes grises. C'est pourtant là
 * qu'on en a le plus besoin : c'est le moment où il faut reconnaître la bête,
 * et un nom latin ne suffit pas à trancher entre deux mésanges. */
async function chargeApercusDe(ids) {
  const manquants = [...new Set(ids)]
    .filter((id) => id && !(id in etat.illustrations)).slice(0, 12);
  if (!manquants.length) return;
  try {
    const d = await appel(`/fiches?cases=${manquants.join(',')}`);
    let neuf = false;
    for (const [id, f] of Object.entries(d.fiches || {})) {
      if (f.image) { etat.illustrations[id] = f.image; neuf = true; }
      // On retient l'absence, sinon la même case serait redemandée à chaque
      // rendu — une requête par trame sur une espèce que Wikipédia ne connaît
      // pas.
      else etat.illustrations[id] = null;
    }
    if (neuf) dessine();
  } catch (_) {
    // Une illustration manquante ne doit pas gêner le choix : la silhouette
    // reste affichée.
  }
}

function vueChoixEspece() {
  const c = etat.choixEspece;
  if (!c) return '';
  const champignon = c.resultats.some((x) => x.regne === 'champignon');
  return `
    <div class="plein">
      <header>
        <button class="retour" onclick="ferme('choixEspece')" aria-label="${t('Retour')}">
          <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
            <path d="M15.4 7.4L14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg></button>
        <h1>${t('Choisir l\'espèce')}</h1>
        <button class="outil" title="${t('Ajouter une espèce absente du dex')}"
                onclick="ouvreNouvelleEspece()">＋</button>
      </header>
      <label class="recherche">
        <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
          <path d="M15.5 14h-.8l-.3-.3a6.5 6.5 0 10-.7.7l.3.3v.8l5 5 1.5-1.5-5-5zm-6 0a4.5 4.5 0 110-9 4.5 4.5 0 010 9z"/></svg>
        <input placeholder="${t('Nom français ou latin…')}" autofocus
               value="${echappe(c.texte)}" oninput="chercheEspece(this.value)">
        ${c.texte ? `<button onclick="chercheEspece('', true)">✕</button>` : ''}
      </label>
      ${champignon ? avertissementChampignon() : ''}
      ${c.charge ? '<div class="filet"></div>' : ''}
      ${listeEspeces(c)}
    </div>`;
}

function listeEspeces(c) {
  if (c.erreur) return `<div class="erreur" style="padding:24px">${echappe(c.erreur)}</div>`;
  if (!c.resultats.length && !c.charge) {
    return messageVide(t('Aucune espèce ne correspond.'),
                       t('Essaie le nom latin, ou un nom plus général.'));
  }
  return `<div class="especes">${c.resultats.map((x) => {
    const illus = etat.illustrations[x.id];
    // Par ordre de préférence : sa propre photo si on l'a déjà trouvée, sinon
    // l'illustration Wikipédia, sinon la silhouette. La première dit « c'est
    // celle-ci que tu as vue », la deuxième aide à trancher, la troisième
    // donne au moins la forme.
    const apercu = x.decoupe
      ? `<img class="decoupe" src="${image(x.decoupe)}" alt="">`
      : (illus ? `<img class="pleine" loading="lazy" decoding="async"
                 src="${image(vignetteWiki(illus, 128))}" alt="">`
               : silhouetteHTML(x.visuel));
    return `
      <div class="ligne espece" data-appui-long="${x.id}"
           data-appui-role="apercu" data-appui-donnees="${apostrophes(x)}">
        <!-- La photo ouvre la fiche, jamais la sélection : c'est le geste
             qu'on fait quand on hésite entre deux espèces voisines. Rester
             appuyé n'importe où sur la ligne fait la même chose, sans avoir à
             viser la vignette. -->
        <span class="apercu-espece" onclick="event.stopPropagation();
              ouvreApercu(${x.id}, ${apostrophes(x)})">${apercu}</span>
        <span class="texte" onclick="retientEspece(${x.id})">
          <b>${echappe(x.nom)}${x.toxique
            ? ` <i class="marque-toxique">${t('TOXIQUE')}</i>` : ''}</b>
          <span class="doux latin">${x.nom_fr
            ? `${echappe(x.latin)} · ${echappe(nomDeClasse(x.classe))}`
            : echappe(nomDeClasse(x.classe))}</span>
        </span>
        ${x.decouvert ? '<span class="deja">✓</span>' : ''}
      </div>`;
  }).join('')}</div>`;
}

/* Les données de la case passent par un attribut `onclick` : il faut donc les
 * sérialiser en JSON dont les guillemets ne cassent pas l'attribut. */
function apostrophes(x) {
  const utile = { nom: x.nom, latin: x.latin, regne: x.regne, toxique: x.toxique,
                  rarete: x.rarete, points: x.points, visuel: x.visuel };
  return echappe(JSON.stringify(utile));
}

async function retientEspece(caseId) {
  // Une correction depuis la visionneuse ne passe pas par `captureEnCours` :
  // cette photo est enregistrée depuis longtemps, elle n'est la « capture en
  // cours » de personne. Confondre les deux replacerait la photo corrigée dans
  // l'écran de prise de vue.
  const aCorriger = etat.choixEspece?.corrige;
  const capture = etat.captureEnCours;
  etat.choixEspece = null;
  if (aCorriger) { await appliqueCorrection(aCorriger, caseId); return; }
  if (capture) await choisitEspece(capture.id, caseId);
  else { etat.vue = 'dex'; dessine(); ouvreFiche(caseId); }
}

/* Corriger l'espèce d'une photo déjà rangée.
 *
 * C'est le geste qui manquait le plus : le moteur se trompe, on le voit en
 * regardant la photo, et il n'y avait rien à faire depuis cet écran. */
function corrigeEspece(captureId) {
  const v = etat.visionneuse;
  etat.choixEspece = {
    texte: '', resultats: [], charge: true, corrige: captureId,
  };
  dessine();
  // On amorce la recherche avec l'espèce actuelle : neuf fois sur dix la bonne
  // réponse est dans le même genre, et le nom est déjà à moitié tapé.
  chercheEspece(v?.nom || '', true);
}

async function appliqueCorrection(captureId, caseId) {
  try {
    await appel(`/captures/${captureId}/espece`,
                { method: 'POST', body: { case_id: caseId } });
    signale(caseId ? 'Espèce corrigée.' : t('Photo détachée.'));
    // La photo a changé d'espèce : la visionneuse affiche encore l'ancienne, et
    // le dex comme la galerie sont périmés.
    if (etat.visionneuse?.id === captureId) {
      if (caseId) etat.visionneuse = await appel(`/captures/${captureId}`);
      else etat.visionneuse = null;
    }
    Object.assign(etat, { trouvees: [], aTrouver: [] });
    chargeGalerie(true);
    chargeResume();
  } catch (e) { signale(e.message, true); }
}

/* Choisir soi-même un champignon n'écarte pas le risque : c'est même le moment
 * où l'on se persuade d'avoir reconnu l'espèce. Le ton est direct parce que
 * l'enjeu l'est. */
const avertissementChampignon = () => `
  <div class="avertissement">
    <span>⚠</span>
    <p>${t('Fiable à 85 % environ. Jouer sa vie sur les 15 % restants serait stupide : ne mangez que ce que vous connaissez déjà. Ce résultat ne doit jamais servir à décider si un champignon se mange.')}</p>
  </div>`;

/* ───────────────────────────────── galerie ───────────────────────────────── */

/* La sélection multiple.
 *
 * Une sortie donne dix photos au même endroit, à quelques minutes près : les
 * corriger une par une, c'est dix fois la même carte et la même heure à
 * repointer. On coche, on pose une fois.
 *
 * On ne coche que ses propres photos : le lieu, la date et les amis d'un
 * cliché appartiennent à celui qui l'a pris. */
function bascule(captureId) {
  if (etat.choisies.has(captureId)) etat.choisies.delete(captureId);
  else etat.choisies.add(captureId);
  dessine();
}

function videSelection() { etat.choisies.clear(); dessine(); }

function barreSelection() {
  const n = etat.choisies.size;
  return `
    <div class="barre-selection">
      <button class="outil" onclick="videSelection()" aria-label="${t('Annuler')}">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
          <path d="M19 6.4L17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19
                   12 13.4 17.6 19 19 17.6 13.4 12z"/></svg></button>
      <b>${t('{0} sélectionnée{1}', [n, n > 1 ? 's' : ''])}</b>
      <button class="secondaire" onclick="situeLesChoisies()">${t('📍 Date et lieu')}</button>
      <button class="secondaire" onclick="identifieChoisies()">${t('👥 Amis')}</button>
    </div>`;
}

/* Pose le même lieu et la même date sur tout le lot.
 *
 * C'est le geste d'une sortie : on rentre, on choisit les vingt photos de
 * l'après-midi, on les pose d'un coup. Les faire une par une, c'est vingt fois
 * la même carte et la même heure à saisir. */
function situeLesChoisies() {
  const lot = [...etat.choisies];
  if (!lot.length) return;
  // On part de la première photo pour préremplir : ses coordonnées et son
  // heure sont le meilleur point de départ, les autres viennent du même
  // moment. La liste peut avoir changé sous nos pieds — un filtre, une
  // suppression : on ne garde que ce qui est encore là.
  const connues = new Map(etat.galerie.map((p) => [p.capture_id, p]));
  const presentes = lot.filter((id) => connues.has(id));
  if (!presentes.length) return;
  const tete = connues.get(presentes[0]);
  ouvreSituer({
    id: tete.capture_id,
    lat: tete.lat, lon: tete.lon, lieu: tete.lieu,
    prise_le: tete.sans_heure ? null : tete.quand,
  }, presentes.slice(1));
}

/* Signe tout le lot des mêmes amis. */
async function identifieChoisies() {
  const lot = [...etat.choisies];
  if (!lot.length) return;
  await ouvreIdentification(lot[0]);
  if (etat.identification) {
    etat.identification.aussi = lot.slice(1);
    // En lot on part d'une liste vide : « déjà identifié » n'a pas de sens
    // quand les photos n'ont pas les mêmes signataires.
    etat.identification.choisis = new Set();
    etat.identification.initiaux = new Set();
    dessine();
  }
}

function vueGalerie() {
  // Le vide garde son en-tête quand il vient d'un filtre : sans lui, il n'y
  // aurait plus aucun moyen de revenir en arrière — l'écran serait un
  // cul-de-sac dont on ne sort qu'en changeant d'onglet.
  if (!etat.galerie.length && !etat.charge) {
    const filtre = combienDeFiltres() > 0;
    return `
      ${filtre ? enteteGalerie() : ''}
      ${etat.filtresGalerieOuverts ? panneauFiltresGalerie() : ''}
      ${filtre
        ? messageVide(t('Rien ne correspond'),
            t('Aucune photo ne passe ces filtres.'),
            `<button class="secondaire" onclick="videFiltres()">${t('Tout effacer')}</button>`)
        : messageVide(t('Rien ici'), t('Aucune photo pour l\'instant.'))}`;
  }
  const enSelection = etat.choisies.size > 0;
  const photos = etat.galerie.map((p) => {
    const choisie = etat.choisies.has(p.capture_id);
    const action = enSelection && p.moi
      ? `bascule(${p.capture_id})`
      : `ouvreVisionneuse(${p.capture_id})`;
    return `
      <div class="tuile ${choisie ? 'choisie' : ''} ${
             enSelection && !choisie ? 'ecartee' : ''}"
           onclick="${action}"
           ${p.moi ? `data-appui-long="${p.capture_id}"
           oncontextmenu="event.preventDefault();bascule(${p.capture_id})"` : ''}>
        <img src="${image(p.vignette)}" alt="" loading="lazy">
        ${p.moi && (p.sans_position || p.sans_heure) ? `
          <span class="repere-situer" title="${[
            p.sans_position ? 'sans lieu' : '',
            p.sans_heure ? 'sans date' : ''].filter(Boolean).join(', ')}"
          >${p.sans_position ? '📍' : ''}${p.sans_heure ? '📅' : ''}</span>` : ''}
        <div class="voile">
          ${p.moi ? '' : avatar(p, 14)}
          <span>${echappe(p.titre || p.nom)}</span>
        </div>
        ${choisie ? '<span class="coche">✓</span>'
          : (p.moi ? `<button class="cocher" aria-label="${t('Sélectionner')}"
                onclick="event.stopPropagation();bascule(${p.capture_id})">○</button>` : '')}
        ${p.favori && !enSelection ? '<span class="etoile">★</span>' : ''}
        ${p.qualite >= 4 && !enSelection
          ? `<span class="gemme q${p.qualite}"></span>` : ''}
      </div>`;
  }).join('');
  return `
    ${enSelection ? barreSelection() : enteteGalerie()}
    ${etat.filtresGalerieOuverts ? panneauFiltresGalerie() : ''}
    <div class="mur">${photos}${
      etat.charge ? '<div class="tuile creuse"></div>'.repeat(3) : ''}</div>`;
}

/* La ligne toujours visible : de qui, et l'accès au reste.
 *
 * « Qui » est sorti du panneau parce que c'est le filtre qu'on manipule le
 * plus — passer de ses photos à celles des amis est un geste courant, il ne
 * doit pas coûter deux ouvertures de menu. */
function enteteGalerie() {
  const n = combienDeFiltres();
  const onglet = (v, texte) => `
    <button class="puce ${etat.fg.qui === v ? 'actif' : ''}" style="--c:var(--accent)"
            onclick="changeFiltre('qui', '${v}')">${texte}</button>`;
  // Quand on a coché des gens en particulier, le filtre ne vaut plus « tous »
  // ni « amis » : on affiche combien, sinon la barre mentirait.
  const choisis = etat.fg.qui.split(',').filter((x) => /^\d+$/.test(x));
  return `
    <div class="entete-galerie">
      <div class="puces">
        ${onglet('tous', t('Tout'))}${onglet('moi', t('Moi'))}${onglet('amis', t('Amis'))}
        ${choisis.length ? `<button class="puce actif" style="--c:var(--accent)"
          onclick="basculeFiltresGalerie()">${t('{0} ami(s)', [choisis.length])}</button>` : ''}
      </div>
      <button class="puce ${n ? 'actif' : ''}" style="--c:var(--accent)"
              onclick="basculeFiltresGalerie()">
        ${t('Filtres{0}', [n ? ` · ${n}` : ''])}
      </button>
    </div>`;
}

function panneauFiltresGalerie() {
  const f = etat.fg;
  const r = etat.reperes;

  const groupe = (cle, choix) => `
    <div class="puces">${choix.map(([v, texte]) => `
      <button class="puce ${f[cle] === v ? 'actif' : ''}" style="--c:var(--accent)"
              onclick="changeFiltre('${cle}', ${typeof v === 'number' ? v : `'${v}'`})"
        >${texte}</button>`).join('')}</div>`;

  return `
    <div class="filtres-galerie">
      <label>${t('Règne')}</label>
      ${groupe('regne', [['', t('Tous')], ['animal', t('🐾 Animaux')],
                         ['plante', t('🌿 Plantes')], ['champignon', t('🍄 Champignons')]])}

      <label>${t('Rareté minimale')}</label>
      ${groupe('qualite', [[0, t('Toutes')], [2, t('Basique +')], [3, t('Peu commun +')],
                           [4, t('Rare +')], [5, t('Légendaire')]])}

      <label>${t('Ce qui manque')}</label>
      <div class="ligne-filtres">
        <label class="case-a-cocher">
          <input type="checkbox" ${f.sansLieu ? 'checked' : ''}
                 onchange="changeFiltre('sansLieu', this.checked)">
          <span>${t('📍 Sans lieu')}</span>
        </label>
        <label class="case-a-cocher">
          <input type="checkbox" ${f.sansDate ? 'checked' : ''}
                 onchange="changeFiltre('sansDate', this.checked)">
          <span>${t('📅 Sans date')}</span>
        </label>
      </div>
      <p class="doux" style="font-size:11.5px;margin:2px 0 0">
        ${t('« Sans lieu » couvre aussi les photos posées par défaut : elles ont des coordonnées, donc apparaissent sur la carte, mais à un endroit que personne n\'a choisi.')}</p>

      <label>${t('Trier par')}</label>
      ${groupe('tri', [['recent', t('Récent')], ['ancien', t('Ancien')],
                       ['espece', t('Espèce')], ['qualite', t('Rareté')],
                       ['lieu', t('Lieu')], ['auteur', t('Auteur')]])}

      <div class="ligne-filtres">
        <label class="case-a-cocher">
          <input type="checkbox" ${f.favoris ? 'checked' : ''}
                 onchange="changeFiltre('favoris', this.checked)">
          <span>${t('★ Favoris seulement')}</span>
        </label>
      </div>

      ${r && r.auteurs.length > 1 ? `
        <label>${t('Qui a pris la photo')}</label>
        <p class="doux" style="font-size:11.5px;margin:0 0 4px">
          ${t('Coche plusieurs personnes pour voir la sortie qu\'on a faite ensemble.')}</p>
        <div class="liste-auteurs">
          ${r.auteurs.map((a) => `
            <label class="case-a-cocher">
              <input type="checkbox" ${amiCoche(a.id) ? 'checked' : ''}
                     onchange="basculeAmi(${a.id})">
              ${avatar(a, 22)}
              <span>${echappe(a.moi ? 'Moi' : a.pseudo)}
                <i class="doux">${a.photos}</i></span>
            </label>`).join('')}
        </div>` : ''}

      ${r && r.lieux.length ? `
        <label>${t('Lieu')}</label>
        <select class="champ" onchange="changeFiltre('lieu', this.value)">
          <option value="">${t('Partout')}</option>
          ${r.lieux.map((l) => `<option value="${echappe(l.lieu)}"
            ${f.lieu === l.lieu ? 'selected' : ''}
            >${echappe(l.lieu)} (${l.photos})</option>`).join('')}
        </select>` : ''}

      ${r && r.especes.length ? `
        <label>${t('Espèce')}</label>
        <select class="champ" onchange="changeFiltre('espece', +this.value)">
          <option value="0">${t('Toutes')}</option>
          ${r.especes.map((e) => `<option value="${e.case_id}"
            ${f.espece === e.case_id ? 'selected' : ''}
            >${echappe(e.nom)} (${e.photos})</option>`).join('')}
        </select>` : ''}

      <label>${t('Entre deux dates')}</label>
      <div class="ligne-filtres">
        <input class="champ" type="date" value="${f.depuis}"
               ${r && r.debut ? `min="${r.debut.slice(0, 10)}"` : ''}
               onchange="changeFiltre('depuis', this.value)">
        <input class="champ" type="date" value="${f.jusqua}"
               ${r && r.fin ? `max="${r.fin.slice(0, 10)}"` : ''}
               onchange="changeFiltre('jusqua', this.value)">
      </div>

      <div class="ligne-filtres">
        <button class="secondaire" onclick="videFiltres()">${t('Tout effacer')}</button>
        <button class="secondaire" onclick="basculeFiltresGalerie()">${t('Fermer')}</button>
      </div>
    </div>`;
}

/* Les cinq réactions, dans l'ordre du serveur.
 *
 * « Bof » vaut zéro point : on peut dire poliment que ce n'est pas la photo du
 * siècle. L'échelle monte de trois en trois ensuite.
 *
 * Cette table avait disparu lors d'une réécriture de la galerie, sans que rien
 * ne le signale : la visionneuse ne l'évalue que sur la photo d'un ami — on ne
 * réagit pas aux siennes — et les essais se faisaient sur ses propres photos.
 * Un `node --check` ne voit rien non plus, la référence étant dans un gabarit.
 */
const REACTIONS = [
  [0, '😐', t('Bof')], [1, '🙂', t('Sympa')], [2, '😮', t('Beau')],
  [3, '🤩', t('Superbe')], [4, '🏆', t('Incroyable')],
];

function vueVisionneuse() {
  const v = etat.visionneuse;
  if (!v) return '';
  const r = etat.reactions || {};
  const mienne = etat.moi && v.utilisateur === etat.moi.id;
  const nom = v.case?.nom_fr || v.case?.latin || v.verdict || 'Sans espèce';

  // On ne note pas ses propres photos : le serveur le refuse, et proposer un
  // bouton qui échoue toujours serait pire que ne rien proposer.
  const boutons = mienne ? '' : `
    <div class="reactions">
      ${REACTIONS.map(([val, emo, n]) => `
        <button class="${r.ma_reaction === val ? 'choisie' : ''}"
                title="${n}" onclick="reagit(${v.id}, ${val})">
          <span>${emo}</span>
          ${r.compte?.[val] ? `<i>${r.compte[val]}</i>` : ''}
        </button>`).join('')}
    </div>`;

  return `
    <div class="feuille feuille-photo" onclick="if(event.target===this)ferme('visionneuse')">
      <div class="corps">
        <div class="poignee"></div>
        <div class="cadre-photo">
          <img class="grande" src="${image(v.photo)}" alt="">
          ${(() => {
            const suite = suiteDeLaVisionneuse();
            const i = rangDansLaSuite();
            if (suite.length < 2 || i < 0) return '';
            return `
              ${i > 0 ? `<button class="fleche gauche" aria-label="${t('Photo précédente')}"
                onclick="glisseVisionneuse(-1)">‹</button>` : ''}
              ${i < suite.length - 1 ? `<button class="fleche droite" aria-label="${t('Photo suivante')}"
                onclick="glisseVisionneuse(1)">›</button>` : ''}
              <span class="rang-photo">${i + 1} / ${suite.length}</span>`;
          })()}
        </div>
        <h2>${echappe(nom)}</h2>
        ${v.case?.latin ? `<div class="latin">${echappe(v.case.latin)}</div>` : ''}
        <p class="doux" style="font-size:13px;margin-top:8px">
          ${echappe(v.pseudo || '')} · ${quand(v.prise_le || v.cree_le)}
          ${v.lieu ? ` · ${echappe(v.lieu)}` : ''}
          ${r.points ? ` ${t('· {0} point(s)', [r.points])}` : ''}</p>
        ${v.titre ? `<p style="font-size:14px">${echappe(v.titre)}</p>` : ''}
        ${boutons}
        ${mienne ? `
          <div class="champ" style="margin-top:14px">
            <label>${t('Légende')}</label>
            <input id="titre_photo" value="${echappe(v.titre || '')}" maxlength="120"
                   onchange="changeTitre(${v.id}, this.value)">
          </div>
          ` : ''}
        ${avecQui(v)}
        ${v.case_id ? `
          <button class="secondaire" style="margin-top:10px"
                  onclick="metVedette(${v.case_id}, ${v.id})">
            ${t('Mettre en avant dans mon dex')}</button>` : ''}
        <div style="display:flex;gap:8px;margin-top:14px;flex-wrap:wrap">
          <button class="secondaire" onclick="basculeFavori(${v.id})">
            ${etat.favori ? '★ Favori' : t('☆ Favori')}</button>
          ${v.case_id ? `<button class="secondaire" onclick="ferme('visionneuse');ouvreFiche(${v.case_id})">
            ${t('Voir l\'espèce')}</button>` : ''}
          ${mienne ? `<button class="secondaire" onclick="corrigeEspece(${v.id})">
            ${t('Corriger l\'espèce')}</button>` : ''}
          ${mienne ? `<button class="secondaire" onclick="ouvreSituer(etat.visionneuse)">
            ${t('Date et lieu')}</button>` : ''}
          ${mienne ? `<button class="secondaire" onclick="ouvreEditeur(${v.id})"
                  title="${t('Ne change que la vignette')}">${t('Détourer')}</button>` : ''}
          <a class="secondaire bouton-lien" download
             href="${image(v.photo)}">${t('Télécharger')}</a>
          ${mienne ? `<button class="secondaire danger" onclick="supprimeCapture(${v.id})">
            ${t('Supprimer')}</button>` : ''}
        </div>
      </div>
    </div>`;
}

/* ────────────────────────────────── amis ────────────────────────────────── */

/* ═══════════════════════════ le fil des amis ═════════════════════════════ */

/* Qui a partagé, en toutes lettres.
 *
 * « Paul et toi », « Paul avec 3 autres ». On ne nomme que ceux qu'on
 * connaît : livrer le pseudo d'un inconnu parce qu'il figure sur la photo d'un
 * ami serait une indiscrétion. */
function titreSortie(g) {
  const noms = (g.gens || []).map((x) => (x.moi ? 'toi' : x.pseudo));
  let qui;
  if (!noms.length) qui = `${g.inconnus} personne${g.inconnus > 1 ? 's' : ''}`;
  else if (noms.length === 1) qui = noms[0];
  else qui = `${noms.slice(0, -1).join(', ')} et ${noms.at(-1)}`;
  if (noms.length && g.inconnus > 0) {
    qui += ` avec ${g.inconnus} autre${g.inconnus > 1 ? 's' : ''}`;
  }
  return qui;
}

/* Ce qu'on a vu, en une ligne : deux noms puis un compte. */
function resumeSortie(g) {
  const e = g.especes || [];
  if (e.length <= 2) return e.join(', ');
  const reste = e.length - 2;
  return `${t('{0} et {1} autre{2}', [e.slice(0, 2).join(', '), reste, reste > 1 ? 's' : ''])}`;
}

/* Une sortie, en une carte.
 *
 * Le fil listait les photos une par une : avec cent amis à trois photos par
 * jour, trois cents cartes à faire défiler pour arriver à celle de la veille.
 * La carte dit qui, quand et ce qui a été vu ; le détail — chaque photo,
 * chaque réaction — vit derrière. */
function carteSortie(g) {
  const vignettes = g.photos.map((p, k) => `
    <div class="cliche" onclick="ouvreSortie('${echappe(g.cle)}', ${k})">
      <img src="${image(p.vignette)}" alt="" loading="lazy">
      ${p.reactions?.total ? `<span class="compte">${p.reactions.total} 👏</span>` : ''}
    </div>`).join('');

  return `
    <div class="sortie ${g.rarete >= 4 ? `belle q${g.rarete}` : ''}">
      <div class="tete">
        <span class="pile">
          ${(g.gens || []).slice(0, 4).map((x, k) =>
            `<span class="rang${k}">${avatar(x, 30)}</span>`).join('')}
        </span>
        <span class="texte">
          <b>${echappe(titreSortie(g))}</b>
          <span class="doux">${t('{0} photo{1}{2}', [g.nb_photos, g.nb_photos > 1 ? 's' : '', 
            resumeSortie(g) ? ` · ${echappe(resumeSortie(g))}` : ''])}</span>
        </span>
        <span class="doux jour">${echappe(g.jour)}</span>
      </div>
      <div class="pellicule">${vignettes}</div>
      <button class="entrer" onclick="ouvreSortie('${echappe(g.cle)}', 0)">
        ${g.reactions
          ? `${t('Voir et réagir · {0} réaction{1}', [g.reactions, g.reactions > 1 ? 's' : ''])}`
          : t('Voir et réagir')} ›</button>
    </div>`;
}

function vueFil() {
  if (etat.chargeFil && !etat.fil.length) {
    return Media.chargement();
  }
  if (!etat.fil.length) {
    return messageVide(t('Rien pour l\'instant'),
                       t('Les trouvailles de tes amis apparaîtront ici.'));
  }
  return `<div class="sorties">${etat.fil.map(carteSortie).join('')}</div>`;
}

async function chargeFil() {
  etat.chargeFil = true;
  try {
    const r = await appel('/fil?limite=25');
    etat.fil = r.groupes || [];
  } catch (e) { etat.erreur = e.message; }
  finally { etat.chargeFil = false; dessine(); }
}

/* ─────────────────────── une sortie dépliée, photo par photo ─────────────── */

/* Les réactions restent attachées à la photo, jamais au groupe : applaudir un
 * lot de six aurait rapporté six fois les points d'un seul geste, et surtout
 * on n'aurait plus pu distinguer la belle photo des cinq autres. Le
 * regroupement est ergonomique, pas comptable. */
function ouvreSortie(cle, debut) {
  const g = etat.fil.find((x) => x.cle === cle);
  if (!g) return;
  etat.sortie = { groupe: g, index: debut };
  dessine();
}

function glisseSortie(pas) {
  const s = etat.sortie;
  if (!s) return;
  const n = s.groupe.photos.length;
  s.index = (s.index + pas + n) % n;
  dessine();
}

async function reagitSortie(captureId, valeur) {
  const s = etat.sortie;
  if (!s) return;
  const photo = s.groupe.photos.find((p) => p.capture_id === captureId);
  const deja = photo?.reactions?.ma_reaction === valeur;
  try {
    if (deja) await appel(`/captures/${captureId}/reaction`, { method: 'DELETE' });
    else await appel(`/captures/${captureId}/reaction`,
                     { method: 'PUT', body: { valeur } });
    const r = await appel(`/captures/${captureId}/reactions`);
    if (photo) {
      // Le total du groupe suit la photo : sinon la carte du fil annoncerait
      // un compte périmé dès qu'on revient en arrière.
      s.groupe.reactions += (r.total || 0) - (photo.reactions?.total || 0);
      photo.reactions = r;
    }
    dessine();
  } catch (e) { signale(e.message, true); }
}

function vueSortie() {
  const s = etat.sortie;
  if (!s) return '';
  const p = s.groupe.photos[s.index];
  const r = p.reactions || {};
  const plusieurs = s.groupe.photos.length > 1;

  return `
    <div class="plein sombre">
      <header class="sur-sombre">
        <button class="retour" onclick="ferme('sortie')" aria-label="${t('Retour')}">
          <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
            <path d="M15.4 7.4L14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg></button>
        <h1>${echappe(titreSortie(s.groupe))}
          <span class="doux">${t('{0} sur {1}', [s.index + 1, s.groupe.photos.length])}</span></h1>
      </header>

      <div class="scene">
        ${plusieurs ? `<button class="fleche gauche" onclick="glisseSortie(-1)"
                              aria-label="${t('Photo précédente')}">‹</button>` : ''}
        <img src="${image(p.vignette)}" alt="">
        ${plusieurs ? `<button class="fleche droite" onclick="glisseSortie(1)"
                              aria-label="${t('Photo suivante')}">›</button>` : ''}
      </div>

      ${plusieurs ? `<div class="bande">
        ${s.groupe.photos.map((x, k) => `
          <img class="${k === s.index ? 'actif' : ''}" src="${image(x.vignette)}"
               alt="" onclick="etat.sortie.index=${k};dessine()">`).join('')}
      </div>` : ''}

      <div class="pied-sortie">
        <div class="ligne-titre">
          <span class="texte">
            <b>${echappe(p.titre || p.nom)}</b>
            ${p.titre ? `<span class="doux">${echappe(p.nom)}</span>` : ''}
            <span class="doux">${[p.pseudo, p.lieu, (p.quand || '').split(' ')[0]]
              .filter(Boolean).map(echappe).join(' · ')}</span>
          </span>
          ${pastilleRarete(p.rarete)}
        </div>
        <div class="reactions">
          ${REACTIONS.map(([val, emo, n]) => `
            <button class="${r.ma_reaction === val ? 'choisie' : ''}"
                    title="${n}" onclick="reagitSortie(${p.capture_id}, ${val})">
              <span>${emo}</span>
              ${r.compte?.[val] ? `<i>${r.compte[val]}</i>` : ''}
            </button>`).join('')}
        </div>
      </div>
    </div>`;
}

function vueAmis() {
  const demandes = etat.demandes.length ? `
    <h3 class="titre">${t('Demandes reçues')}</h3>
    ${etat.demandes.map((d) => `
      <div class="ligne">
        ${avatar(d)}
        <span class="texte"><b>${echappe(d.pseudo)}</b>
          <span class="doux">${t('{0} espèce(s)', [d.cases ?? 0])}</span></span>
        <button class="secondaire" onclick="repondDemande(${d.demande_id}, 'accepter')">${t('Accepter')}</button>
        <button class="secondaire" onclick="repondDemande(${d.demande_id}, 'refuser')">${t('Refuser')}</button>
      </div>`).join('')}` : '';

  const trouves = etat.rechercheAmis.length ? `
    <h3 class="titre">${t('Résultats')}</h3>
    ${etat.rechercheAmis.map((u) => `
      <div class="ligne">
        ${avatar(u)}
        <span class="texte"><b>${echappe(u.pseudo)}</b>
          <span class="doux">${t('{0} espèce(s)', [u.cases ?? 0])}</span></span>
        ${bouton(u)}
      </div>`).join('')}` : '';

  // Le classement est un troisième onglet et non une entrée du profil : on le
  // regarde pour se comparer à ses amis, donc c'est ici qu'on le cherche. Il
  // restait rangé dans les réglages, où personne n'allait le trouver.
  const onglets = `
    <div class="segments">
      ${[['fil', t('Fil')], ['gens', t('Mes amis')], ['classement', t('Classement')]].map(([k, n]) => `
        <button class="${etat.ongletAmis === k ? 'actif' : ''}"
                onclick="etat.ongletAmis='${k}';dessine();${
                  k === 'fil' ? 'if(!etat.fil.length)chargeFil()'
                  : k === 'classement' ? 'if(!etat.classement.length)chargeClassement()' : ''}">
          ${n}${k === 'gens' && etat.demandes.length
                ? ` <i class="compteur">${etat.demandes.length}</i>` : ''}</button>`).join('')}
    </div>`;

  if (etat.ongletAmis === 'fil') return `${onglets}${vueFil()}`;
  if (etat.ongletAmis === 'classement') return `${onglets}${vueClassement()}`;

  return `
    ${onglets}
    <label class="recherche">
      <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor">
        <path d="M15.5 14h-.8l-.3-.3a6.5 6.5 0 10-.7.7l.3.3v.8l5 5 1.5-1.5-5-5zm-6 0a4.5 4.5 0 110-9 4.5 4.5 0 010 9z"/></svg>
      <input placeholder="${t('Chercher un joueur…')}" oninput="chercheAmis(this.value)">
    </label>
    ${demandes}
    ${trouves}
    <h3 class="titre">${t('Mes amis')}</h3>
    ${etat.amis.length ? etat.amis.map((a) => `
      <div class="ligne" onclick="ouvreJoueur(${a.id})">
        ${avatar(a, 40, false)}
        <span class="texte"><b>${echappe(a.pseudo)}</b>
          <span class="doux">${t('{0} espèce(s)', [a.cases ?? 0])}</span></span>
      </div>`).join('') : `<div class="vide">${t('Personne pour l\'instant.')}</div>`}`;
}

/* Ce qu'on propose selon la relation. Les cinq états viennent tels quels de
 * l'API : aucune, envoyee, recue, amis, moi. */
function bouton(u) {
  if (u.relation === 'amis') return `<span class="doux">${t('Ami')}</span>`;
  if (u.relation === 'moi') return `<span class="doux">${t('C\'est toi')}</span>`;
  if (u.relation === 'envoyee') return `<span class="doux">${t('Demandé')}</span>`;
  if (u.relation === 'recue') return `<span class="doux">${t('T\'a demandé')}</span>`;
  if (u.relation === 'bloquee') return '';
  return `<button class="secondaire" onclick="demandeAmi('${echappe(u.pseudo)}')">${t('Ajouter')}</button>`;
}

/* Un avatar mène au profil de son propriétaire.
 *
 * C'est le geste qu'on essaie d'instinct : on voit une tête à côté d'un pseudo,
 * on la touche pour savoir qui c'est. Il ne faisait rien — sauf dans la liste
 * d'amis, où c'était la ligne entière qui réagissait.
 *
 * `avecLien` reste possible pour les rares endroits où l'avatar est déjà dans
 * un élément cliquable qui va ailleurs : deux gestes concurrents au même
 * endroit, l'un annulerait l'autre. */
function avatar(u, taille = 40, avecLien = true) {
  const st = `style="width:${taille}px;height:${taille}px;font-size:${
    Math.round(taille * 0.42)}px"`;
  const id = u.id ?? u.utilisateur;
  const lien = avecLien && id
    ? ` role="button" tabindex="0" class="avatar-lien"
        onclick="event.stopPropagation();ouvreJoueur(${id})"` : '';
  return u.avatar
    ? `<img class="avatar" ${st}${lien} src="${image(u.avatar)}" alt="">`
    : `<span class="avatar vide-av" ${st}${lien}>${
        echappe((u.pseudo || '?')[0].toUpperCase())}</span>`;
}

/* ─────────────────────────────── classement ─────────────────────────────── */

function vueClassement() {
  // Deux façons de lire le même cercle d'amis : qui mène, et ce qui a été
  // trouvé de plus beau. La seconde manquait au site — c'est pourtant celle
  // qui donne envie de sortir, un rang ne montre aucune bête.
  const onglets = `
    <div class="puces" style="margin-bottom:8px">
      ${[['joueurs', t('Classement')], ['trouvailles', t('Belles prises')]].map(([k, n]) => `
        <button class="puce ${etat.ongletClassement === k ? 'actif' : ''}"
                style="--c:var(--accent)"
                onclick="ongletDuClassement('${k}')">${n}</button>`).join('')}
    </div>`;

  // Où j'en suis, avant la liste : l'application le dit en tête, et c'est la
  // première chose qu'on vient chercher ici.
  const moi = etat.classementMoi;
  const tete = moi ? `
    <div class="classement-moi">
      <b>${moi.rang}<sup>e</sup> ${t('sur {0}', [moi.sur])}</b>
      <span class="doux">${t('{0} points{1}', [moi.total, moi.points_reactions
        ? ` ${t('· dont {0} 👏', [moi.points_reactions])}` : ''])}</span>
    </div>` : '';

  if (etat.ongletClassement === 'trouvailles') {
    return onglets + tete + (etat.trouvailles
      ? (etat.trouvailles.length
        ? `<div class="mur serre">${etat.trouvailles.map((m) => `
            <div class="tuile" onclick="ouvreFiche(${m.case_id})"
                 title="${echappe(`${m.nom} — ${m.pseudo}`)}">
              <img src="${image(photoDePiece(m))}" alt="" loading="lazy">
              <span class="gemme q${m.qualite}"></span>
              <div class="voile"><span>${echappe(m.moi ? m.nom : m.pseudo)}</span></div>
            </div>`).join('')}</div>`
        : messageVide(t('Rien encore'), t('Aucune trouvaille à montrer.')))
      : Media.chargement());
  }

  if (!etat.classement.length) return onglets + tete + Media.chargement();
  return onglets + tete + etat.classement.map((j) => `
    <div class="ligne ${j.moi ? 'moi' : ''}" onclick="ouvreJoueur(${j.id})">
      <span class="rang">${j.rang}</span>
      ${avatar(j, 40, false)}
      <span class="texte"><b>${echappe(j.pseudo)}</b>
        <span class="doux">${t('{0} espèce(s){1}', [j.cases ?? 0, 
          j.palier?.nom ? ` · ${echappe(j.palier.nom)}` : ''])}</span></span>
      <b>${j.points ?? 0}</b>
    </div>`).join('');
}

/* ─────────────────────────────── notifications ─────────────────────────── */

/* Ce que raconte chaque notification. Le texte prend l'émoji de la réaction
 * quand il y en a un : « 🤩 sur ton Renard roux » se lit d'un coup. */
function texteNotif(n) {
  if (n.type === 'reaction') {
    return `${n.emoji || ''} ${n.reaction || 'a réagi'}${
      n.espece ? ` ${t('sur ton {0}', [n.espece])}` : t('sur ta photo')}`;
  }
  if (n.type === 'identifie') {
    return `${t('t\'a identifié sur sa photo{0}', [n.espece ? ` ${t('de {0}', [n.espece])}` : ''])}`;
  }
  if (n.type === 'ami_demande') return t('t\'a envoyé une demande d\'ami');
  if (n.type === 'ami_accepte') return t('a accepté ta demande');
  if (n.type === 'favori') return t('a mis ta photo en favori');
  if (n.type === 'espece_ajoutee') return t('a indexé une espèce absente du dex');
  // `nb_trouvailles` compte les photos regroupées sous cette seule
  // notification : le serveur n'en ouvre pas une par photo, il fait grossir
  // celle-ci tant qu'elle n'a pas été lue.
  if (n.type === 'ami_actif') {
    return n.nb_trouvailles > 1
      ? `${t('a partagé {0} nouvelles trouvailles', [n.nb_trouvailles])}`
      : t('a partagé une nouvelle trouvaille');
  }
  if (n.type === 'purge') {
    // `valeur` porte le nombre de jours restants, ou -1 quand les photos
    // n'ont pas toutes le même délai : on reste alors vague plutôt que de
    // donner un chiffre faux.
    return n.valeur > 0
      ? `${t('il reste {0} jour{1} à tes photos indéterminées', [n.valeur, n.valeur > 1 ? 's' : ''])}`
      : t('tes photos indéterminées vont bientôt se supprimer');
  }
  return n.type;
}

/* La date à montrer sur une ligne, selon le réglage courant.
 *
 * `prise_le` manque pour beaucoup de types — une demande d'ami n'a pas de
 * date de prise de vue — d'où le repli sur `cree_le`, toujours renseignée. */
function dateNotif(n) {
  if (etat.dateNotifsSelon === 'prise' && n.prise_le) return n.prise_le;
  return n.cree_le;
}

function basculeDateNotifs() {
  etat.dateNotifsSelon = etat.dateNotifsSelon === 'prise' ? 'publication' : 'prise';
  localStorage.setItem('biodex_date_notifs', etat.dateNotifsSelon);
  dessine();
}

/* Où mène le clic sur une ligne.
 *
 * `ami_actif` ne désigne aucune photo précise — c'est un ami qui a été actif,
 * pas une trouvaille en particulier — cliquer mène donc à son profil plutôt
 * qu'à une photo choisie au hasard parmi les siennes. Les autres types qui
 * portent une photo (réaction, identification) l'ouvrent directement : c'est
 * elle qui a provoqué la notification.
 */
function ouvreNotif(captureId, type, auteurId) {
  if (captureId) ouvreVisionneuse(captureId);
  else if (type === 'ami_actif' && auteurId) ouvreJoueur(auteurId);
}

function vueNotifications() {
  const reglages = `<div class="rangee-centree haut-page">
    <button class="lien" onclick="va('reglagesnotifs')">${t('⚙ Ce dont je veux être prévenu')}</button>
    <button class="lien" onclick="basculeDateNotifs()">
      🕓 ${etat.dateNotifsSelon === 'prise' ? 'Prise de vue' : t('Publication')}</button>
    ${etat.notifications.length ? `<button class="lien" onclick="videNotifications()">
      ${t('🗑 Tout effacer')}</button>` : ''}
  </div>`;
  if (!etat.notifications.length) {
    return reglages + `<div class="vide">${t('Aucune notification.')}</div>`;
  }
  return reglages + etat.notifications.map((n) => `
    <div class="ligne ${n.lu ? '' : 'neuf'}"
         onclick="ouvreNotif(${n.capture_id ?? 'null'}, '${n.type}', ${n.auteur ?? 'null'})">
      ${avatar(n)}
      <span class="texte">
        <b>${echappe(n.pseudo)}</b>
        <span class="doux">${echappe(texteNotif(n))} · ${quand(dateNotif(n))}</span>
      </span>
      <!-- La vignette, jamais la découpe : la découpe garde la proportion de
           l'animal détouré — de 0,9:1 à 1,6:1 selon la bête — et recadrée dans
           un carré de quarante pixels, elle tronque la tête aussi souvent
           qu'autre chose. La vignette a toujours les mêmes proportions. -->
      ${n.vignette ? `<img class="minia" src="${image(n.vignette)}${
        n.vignette.includes('?') ? '&' : '?'}taille=96" alt="">` : ''}
    </div>`).join('');
}

/* ───────────────────────────────── paliers ───────────────────────────────── */

function vuePaliers() {
  const p = etat.paliers;
  if (!p) return Media.chargement();
  const liste = p.paliers || [];
  const suivant = liste.find((b) => !b.atteint);
  return `
    <div class="resume-paliers">
      <b>${p.trouve}</b> ${t('espèce(s) trouvée(s) · palier {0}/{1} {2}', [p.atteint, liste.length, suivant ? `
        <div class="jauge"><div style="width:${
          (100 * Math.min(1, p.trouve / Math.max(1, suivant.seuil))).toFixed(1)}%"></div></div>
        <div class="doux" style="font-size:12px;margin-top:6px">
          ${t('Encore {0} pour « {1} »', [suivant.seuil - p.trouve, echappe(suivant.nom)])}</div>`
        : `<div class="doux" style="font-size:12px;margin-top:6px">${t('Tous les paliers sont atteints.')}</div>`])}
    </div>
    <div class="badges">
      ${liste.map((b) => `
        <div class="badge ${b.atteint ? '' : 'verrouille'}">
          ${b.badge ? `<img src="${image(b.badge)}" alt="">` : '<div class="rond"></div>'}
          <b class="nom-palier">${echappe(b.nom)}</b>
          <span class="doux">${t('{0} espèce{1}', [b.seuil, b.seuil > 1 ? 's' : ''])}</span>
        </div>`).join('')}
    </div>`;
}

/* ────────────────────────────────── profil ──────────────────────────────── */

/* Le profil : qui on est, et par où l'on va.
 *
 * C'était un empilement — une carte d'identité, sept boutons sans intitulé, un
 * réglage d'affichage, une clé d'interface externe, une bio, un mot de passe.
 * Autant de choses de natures différentes à la file, et rien pour dire laquelle
 * on cherchait.
 *
 * Il ne reste ici que **ce qui vous appartient** : votre identité, votre
 * progression, et les écrans qui montrent vos affaires. Tout ce qui se règle a
 * déménagé dans « Réglages » — un seul endroit où chercher quand on veut
 * changer quelque chose.
 */
function vueProfil() {
  const m = etat.moi;
  if (!m) return Media.chargement();
  const r = etat.resume;
  const pal = r?.palier;

  const entree = (vue, emoji, titre, detail, action = null) => `
    <button class="entree-menu" onclick="${action || `va('${vue}')`}">
      <span class="emoji" aria-hidden="true">${emoji}</span>
      <span class="texte"><b>${titre}</b><span class="doux">${detail}</span></span>
      <svg class="chevron" viewBox="0 0 24 24" width="18" height="18" fill="currentColor"
           aria-hidden="true"><path d="M9.4 18L8 16.6l4.6-4.6L8 7.4 9.4 6l6 6z"/></svg>
    </button>`;

  return `
    <div class="centre">
      <div class="carte-identite">
        <label class="change-avatar" title="${t('Changer ma photo')}">
          <input type="file" accept="image/*" hidden onchange="envoieAvatar(this)">
          ${m.avatar
            ? `<img class="avatar grand" src="${image(m.avatar)}" alt="">`
            : `<span class="avatar grand vide-av">${
                echappe((m.pseudo || '?')[0].toUpperCase())}</span>`}
          <span class="stylo" aria-hidden="true">✎</span>
        </label>
        <h2>${echappe(m.pseudo)}</h2>
        ${m.bio ? `<p class="bio">${echappe(m.bio)}</p>` : ''}

        <div class="chiffres">
          <span><b>${m.cases ?? 0}</b>${t('espèces')}</span>
          <span><b>${m.captures ?? 0}</b>${t('photos')}</span>
          <span><b>${m.points ?? 0}</b>${t('points')}</span>
        </div>

        ${pal?.nom ? `
          <div class="progression" onclick="va('paliers')">
            <div class="ligne-progression">
              <b>${echappe(pal.nom)}</b>
              ${pal.suivant ? `<span class="doux">${t('encore {0}', [pal.reste])}</span>` : ''}
            </div>
            ${pal.suivant ? `<span class="piste"><i style="width:${
              Math.max(2, Math.min(100, Math.round(100 - (pal.reste / Math.max(1, pal.reste + (r.trouve || 1))) * 100)))}%"></i></span>
            <span class="doux">${t('vers « {0} »', [echappe(pal.suivant)])}</span>` : ''}
          </div>` : ''}
      </div>

      <h3 class="titre-section">${t('Mes affaires')}</h3>
      <div class="menu-range">
        ${entree(null, '👤', t('Mon profil public'), t('Ce que voient les autres'),
                 'ouvreJoueur(etat.moi.id)')}
        ${(r?.classes || []).some((g) => g.trouve > 0) ? `
          <!-- Seuls les groupes déjà entamés : la liste complète ferait
               quarante lignes à zéro, ce qui n'apprend rien. -->
          <div class="groupes-profil">
            <h3 class="titre" style="margin-left:0">${t('Par groupe')}</h3>
            ${r.classes.filter((g) => g.trouve > 0).map((g) => `
              <div class="ligne-groupe">
                <span class="nom">${echappe(nomDeTaxon(g.classe))}</span>
                <span class="jauge"><i style="width:${
                  (100 * g.trouve / Math.max(1, g.total)).toFixed(1)}%"></i></span>
                <span class="doux">${g.trouve} / ${g.total}</span>
              </div>`).join('')}
          </div>` : ''}
        ${entree('vitrine', '🏆', t('Vitrine et succès'), t('Ce que j\'ai décroché'))}
        ${entree('paliers', '🎖', t('Mes paliers'), t('Les 50 rangs du dex'))}
        ${entree('mescaptures', '🖼', t('Mes photos'), t('Toutes, y compris non identifiées'))}
      </div>

      <h3 class="titre-section">${t('Explorer')}</h3>
      <div class="menu-range">
        ${entree('carte', '🗺', t('La carte'), t('Où j\'ai trouvé quoi'))}
        ${entree('classement', '📊', t('Classement'), t('Mon cercle d\'amis'))}
      </div>

      <h3 class="titre-section">${t('L\'application')}</h3>
      <div class="menu-range">
        ${entree('reglages', '⚙️', t('Réglages'), t('Thème, animations, notifications'))}
        ${entree('credits', 'ℹ️', t('Crédits'), t('D\'où viennent les silhouettes'))}
      </div>
    </div>`;
}

/* Les états d'une photo, tels qu'on les filtre.
 *
 * Mêmes intitulés que dans l'application, et dans le même ordre : c'est le
 * même écran, et deux vocabulaires pour une même chose obligeraient à
 * réapprendre en changeant d'appareil. Le serveur sait déjà filtrer là-dessus
 * (`GET /captures?etat=`), il n'y avait que le site à le lui demander. */
const FILTRES_PHOTOS = [
  ['tout', t('Toutes')], ['ok', t('Reconnues')],
  ['doute', t('À trancher')], ['rejet', t('Refusées')],
];

function filtrePhotos(cle) {
  etat.filtrePhotos = cle;
  // Changer de filtre vide la sélection : les identifiants retenus
  // désigneraient des photos que l'écran ne montre plus, et « Tout
  // sélectionner » compterait faux.
  etat.choisiesPhotos.clear();
  etat.modeTriPhotos = false;
  chargeMesCaptures();
}

function entreDansLeTriPhotos() { etat.modeTriPhotos = true; dessine(); }

function sortDuTriPhotos() {
  etat.modeTriPhotos = false;
  etat.choisiesPhotos.clear();
  dessine();
}

function basculePhoto(id) {
  if (etat.choisiesPhotos.has(id)) etat.choisiesPhotos.delete(id);
  else etat.choisiesPhotos.add(id);
  dessine();
}

function toutesLesPhotos() {
  const deja = etat.mesCaptures.length === etat.choisiesPhotos.size;
  etat.choisiesPhotos.clear();
  if (!deja) etat.mesCaptures.forEach((c) => etat.choisiesPhotos.add(c.id));
  dessine();
}

/* Poser le même lieu et la même date sur tout le lot.
 *
 * La première photo préremplit la carte : ses coordonnées sont le meilleur
 * point de départ, les autres viennent de la même sortie. */
function situePhotosChoisies() {
  const connues = new Map(etat.mesCaptures.map((c) => [c.id, c]));
  const lot = [...etat.choisiesPhotos].filter((id) => connues.has(id));
  if (!lot.length) return;
  const tete = connues.get(lot[0]);
  ouvreSituer({ id: tete.id, lat: tete.lat, lon: tete.lon,
                lieu: tete.lieu, prise_le: tete.prise_le }, lot.slice(1));
}

/* Signer tout le lot des mêmes amis. */
async function identifiePhotosChoisies() {
  const lot = [...etat.choisiesPhotos];
  if (!lot.length) return;
  await ouvreIdentification(lot[0]);
  if (etat.identification) {
    etat.identification.aussi = lot.slice(1);
    // En lot on part d'une liste vide : « déjà identifié » n'a pas de sens
    // quand les photos n'ont pas les mêmes signataires.
    etat.identification.choisis = new Set();
    etat.identification.initiaux = new Set();
    dessine();
  }
}

/* Jeter les photos sans espèce de la sélection.
 *
 * Le compte annoncé est celui des photos **sans espèce** qu'elle contient, pas
 * sa taille : le serveur épargne les autres, et promettre vingt suppressions
 * pour en faire trois serait mentir. « Tout » puis « Supprimer » reste donc un
 * geste sûr, y compris depuis l'onglet « Toutes ». */
async function supprimePhotosChoisies() {
  const connues = new Map(etat.mesCaptures.map((c) => [c.id, c]));
  const lot = [...etat.choisiesPhotos].filter(
    (id) => connues.has(id) && connues.get(id).case_id == null);
  const gardees = etat.choisiesPhotos.size - lot.length;
  if (!lot.length) {
    signale(t('Aucune photo sans espèce dans la sélection.'), true);
    return;
  }
  if (!confirm(`${t('Supprimer {0} photo(s) ?\\n\\n', [lot.length])}`
               + t('Les images et leurs données partent définitivement.')
               + (gardees ? `${t('\\n\\n{0} photo(s) de la sélection sont', [gardees])} `
                          + 'rattachées à une espèce : elles seront gardées.' : ''))) {
    return;
  }
  try {
    const r = await appel('/captures/non-identifiees/suppression',
                          { method: 'POST', body: { ids: lot } });
    sortDuTriPhotos();
    signale(`${t('{0} photo(s) supprimée(s).', [r.supprimees])}`);
    chargeMesCaptures();
    chargeResume();
  } catch (e) { signale(e.message, true); }
}

function vueMesCaptures() {
  const f = etat.filtrePhotos || 'tout';
  const tri = etat.choisiesPhotos;
  const enTri = etat.modeTriPhotos;

  // « Espèces indexées » est une porte, pas un filtre : ce qu'on a indexé
  // soi-même n'est pas un état de capture, et le ranger parmi les états
  // laisserait croire que c'en est un.
  const porte = `<div class="rangee-centree haut-page">
    <button class="lien" onclick="va('mesespeces')">${t('🌱 Espèces indexées')}</button>
    <button class="lien" onclick="${enTri ? 'sortDuTriPhotos()' : 'entreDansLeTriPhotos()'}">
      ${enTri ? 'Terminer' : t('Sélectionner')}</button>
  </div>`;

  const puces = `
    <div class="puces" style="margin-bottom:8px">
      ${FILTRES_PHOTOS.map(([k, n]) => `
        <button class="puce ${f === k ? 'actif' : ''}" style="--c:var(--accent)"
                onclick="filtrePhotos('${k}')">${n}</button>`).join('')}
    </div>`;

  const barre = enTri ? `
    <div class="barre-selection">
      <button class="outil" onclick="sortDuTriPhotos()" aria-label="${t('Annuler')}">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
          <path d="M19 6.4L17.6 5 12 10.6 6.4 5 5 6.4 10.6 12 5 17.6 6.4 19
                   12 13.4 17.6 19 19 17.6 13.4 12z"/></svg></button>
      <b>${t('{0} sélectionnée{1}', [tri.size, tri.size > 1 ? 's' : ''])}</b>
      <button class="secondaire" onclick="toutesLesPhotos()">${t('Tout')}</button>
      <button class="secondaire" ${tri.size ? '' : 'disabled'}
              onclick="situePhotosChoisies()">${t('📍 Date et lieu')}</button>
      <button class="secondaire" ${tri.size ? '' : 'disabled'}
              onclick="identifiePhotosChoisies()">${t('👥 Amis')}</button>
      <button class="secondaire danger" ${tri.size ? '' : 'disabled'}
              onclick="supprimePhotosChoisies()">${t('Supprimer')}</button>
    </div>` : '';

  if (!etat.mesCaptures.length) {
    // L'en-tête survit au vide : sans lui, un filtre sans résultat serait un
    // cul-de-sac dont on ne sortirait qu'en changeant d'onglet.
    return porte + puces + messageVide(
      t('Rien ici'),
      f === 'tout' ? t('Aucune photo pour l\'instant.')
                   : t('Aucune photo dans cet état.'));
  }

  return porte + puces + barre + `<div class="mur">${etat.mesCaptures.map((c) => {
    const prise = tri.has(c.id);
    return `
    <div class="tuile ${prise ? 'choisie' : ''} ${enTri && !prise ? 'ecartee' : ''}"
         onclick="${enTri ? `basculePhoto(${c.id})` : `ouvreVisionneuse(${c.id})`}">
      <img src="${image(c.vignette)}" alt="" loading="lazy">
      ${prise ? '<span class="coche">✓</span>' : ''}
      <div class="voile">
        <span>${echappe(c.titre || c.case?.nom_fr || c.case?.latin
                        || c.verdict || 'Sans espèce')}</span>
      </div>
    </div>`;
  }).join('')}</div>`;
}

/* La carte, et ce qui l'accompagne.
 *
 * Trois choses, comme sur l'application : le plan, la liste par lieu — c'est
 * elle qu'on regarde pour se souvenir d'une sortie — et les photos qui
 * attendent d'être situées.
 */
/* La carte : où mes amis et moi avons trouvé quoi.
 *
 * Pensée pour regarder chez les autres. Ce qu'on vient y chercher, ce sont les
 * photos qu'on n'a pas encore vues — d'où « Nouveautés » par défaut tant qu'il
 * en reste, et « Tout voir » d'un appui. Les filtres disent *qui* : tout le
 * monde, moi, tel ou tel ami, avec le nombre de nouveautés sur chaque tête.
 *
 * Les points sont tous chargés d'un coup (deux mille au plus) et filtrés ici :
 * changer de filtre ne coûte aucun aller-retour, la carte réagit au doigt. */
function pointsCarteFiltres() {
  const f = etat.filtreCarte;
  const nouveautes = nouveautesCarte();
  return etat.carte.filter((p) => {
    // `qui` : 'tous', 'moi', 'amis', ou un ensemble de personnes cochées —
    // 'moi' et des identifiants d'amis.
    if (f.qui === 'moi' && !p.moi) return false;
    if (f.qui === 'amis' && p.moi) return false;
    if (f.qui instanceof Set && !f.qui.has(p.moi ? 'moi' : p.utilisateur)) return false;
    if (f.regne && (p.regne || 'animal') !== f.regne) return false;
    if (nouveautes && (p.vue || p.moi)) return false;
    return true;
  });
}

/* « Nouveautés » tant qu'il y en a, « Tout voir » sinon — sauf si on a choisi. */
function nouveautesCarte() {
  const f = etat.filtreCarte;
  if (f.nouveautes !== null) return f.nouveautes;
  return etat.carte.some((p) => !p.vue && !p.moi);
}

/* Les amis présents sur la carte, avec ce que je n'ai pas encore vu chez eux. */
function amisDeLaCarte() {
  const par = new Map();
  for (const p of etat.carte) {
    if (p.moi) continue;
    if (!par.has(p.utilisateur)) {
      par.set(p.utilisateur, { id: p.utilisateur, pseudo: p.pseudo, avatar: p.avatar,
                               total: 0, nouvelles: 0 });
    }
    const a = par.get(p.utilisateur);
    a.total += 1;
    if (!p.vue) a.nouvelles += 1;
  }
  // Ceux qui ont du neuf d'abord, puis par volume : c'est l'ordre dans lequel
  // on a envie de regarder.
  return [...par.values()].sort((x, y) => (y.nouvelles - x.nouvelles) || (y.total - x.total));
}

/* « Tout / Moi / Amis » d'un appui ; des personnes précises en les cochant
 * dans le panneau, comme dans la galerie. */
function filtreQui(valeur) {
  etat.filtreCarte.qui = valeur;
  dessine();
}

function basculeAmiCarte(cle) {
  const f = etat.filtreCarte;
  const s = new Set(f.qui instanceof Set ? f.qui : []);
  if (s.has(cle)) s.delete(cle); else s.add(cle);
  f.qui = s.size ? s : 'tous';
  dessine();
}

function basculeFiltresCarte() {
  etat.filtresCarteOuverts = !etat.filtresCarteOuverts;
  dessine();
}

function chercheAmiCarte(v) {
  etat.rechercheAmiCarte = v;
  const l = document.querySelector('.filtres-galerie .liste-auteurs');
  if (l) l.outerHTML = listeAmisCarte();
}

function videFiltresCarte() {
  etat.filtreCarte = { qui: 'tous', nouveautes: null, regne: null };
  etat.rechercheAmiCarte = '';
  dessine();
}

function combienDeFiltresCarte() {
  const f = etat.filtreCarte;
  return (f.qui instanceof Set ? 1 : 0) + (f.regne ? 1 : 0);
}

/* La taille des bulles sur la carte : un réglage, parce que quarante photos
 * au même endroit ne se lisent pas comme quatre, et parce que l'écran d'une
 * tablette n'est pas celui d'un téléphone. */
const TAILLES_BULLES = { petite: 34, moyenne: 44, grande: 56 };
function tailleBulles() {
  const v = localStorage.getItem('biodex_taille_bulles');
  return TAILLES_BULLES[v] ? v : 'moyenne';
}
function changeTailleBulles(v) {
  if (!TAILLES_BULLES[v]) return;
  localStorage.setItem('biodex_taille_bulles', v);
  dessine();
}
const puceTailleBulles = () => `
  <div class="puces" style="padding:0">${Object.entries(TAILLES_BULLES).map(([k, px]) => `
    <button class="puce ${tailleBulles() === k ? 'actif' : ''}" style="--c:var(--accent)"
            onclick="changeTailleBulles('${k}')" title="${t('{0} px', [px])}">
      <i class="apercu-bulle" style="width:${Math.round(px / 2.2)}px;height:${Math.round(px / 2.2)}px"></i>
      ${k[0].toUpperCase() + k.slice(1)}</button>`).join('')}</div>`;

/* La liste des amis à cocher, avec ce qu'il reste à voir chez chacun. Une
 * recherche dès qu'ils sont nombreux : quarante têtes ne se parcourent pas. */
function listeAmisCarte() {
  const f = etat.filtreCarte;
  const q = (etat.rechercheAmiCarte || '').trim().toLowerCase();
  const amis = amisDeLaCarte().filter((a) => !q || a.pseudo.toLowerCase().includes(q));
  const coche = (cle) => f.qui instanceof Set && f.qui.has(cle);
  const miennes = etat.carte.filter((p) => p.moi).length;
  return `
    <div class="liste-auteurs">
      ${!q || 'moi'.includes(q) ? `
        <label class="case-a-cocher">
          <input type="checkbox" ${coche('moi') ? 'checked' : ''} onchange="basculeAmiCarte('moi')">
          ${avatar(etat.moi || { pseudo: '?' }, 22, false)}
          <span>${t('Moi')} <i class="doux">${miennes}</i></span>
        </label>` : ''}
      ${amis.map((a) => `
        <label class="case-a-cocher">
          <input type="checkbox" ${coche(a.id) ? 'checked' : ''} onchange="basculeAmiCarte(${a.id})">
          ${avatar(a, 22, false)}
          <span>${echappe(a.pseudo)} <i class="doux">${a.total}</i></span>
          ${a.nouvelles ? `<i class="badge-neuf">${a.nouvelles}</i>` : ''}
        </label>`).join('')}
      ${!amis.length && q ? `<span class="doux" style="font-size:12.5px">${t('Personne ne s\'appelle comme ça.')}</span>` : ''}
    </div>`;
}

function panneauFiltresCarte() {
  const f = etat.filtreCarte;
  const amis = amisDeLaCarte();
  const groupe = (cle, choix, action) => `
    <div class="puces">${choix.map(([v, texte]) => `
      <button class="puce ${f[cle] === v ? 'actif' : ''}" style="--c:var(--accent)"
              onclick="${action(v)}">${texte}</button>`).join('')}</div>`;
  return `
    <div class="filtres-galerie">
      <label>${t('Règne')}</label>
      ${groupe('regne', [[null, t('Tous')], ['animal', t('🐾 Animaux')],
                         ['plante', t('🌿 Plantes')], ['champignon', t('🍄 Champignons')]],
               (v) => `filtreRegneCarte(${v === null ? 'null' : `'${v}'`})`)}

      <label>${t('Taille des bulles')}</label>
      ${puceTailleBulles()}

      ${amis.length ? `
        <label>${t('Qui a pris la photo')}</label>
        <p class="doux" style="font-size:11.5px;margin:0 0 4px">
          ${t('Coche une ou plusieurs personnes. Le chiffre rouge, c\'est ce que tu n\'as pas encore vu chez elles.')}</p>
        ${amis.length > 6 ? `
          <input class="champ" type="search" placeholder="${t('Chercher un ami')}"
                 value="${echappe(etat.rechercheAmiCarte || '')}"
                 oninput="chercheAmiCarte(this.value)">` : ''}
        ${listeAmisCarte()}` : ''}

      <div class="ligne-filtres">
        <button class="secondaire" onclick="videFiltresCarte()">${t('Tout effacer')}</button>
        <button class="secondaire" onclick="basculeFiltresCarte()">${t('Fermer')}</button>
      </div>
    </div>`;
}

function filtreNouveautes(valeur) {
  etat.filtreCarte.nouveautes = valeur;
  dessine();
}

function filtreRegneCarte(r) {
  etat.filtreCarte.regne = (r === null || etat.filtreCarte.regne === r) ? null : r;
  dessine();
}

const REGNES_CARTE = [['animal', '🐾', t('Animaux')], ['plante', '🌿', t('Plantes')],
                      ['champignon', '🍄', t('Champignons')]];

function vueCarte() {
  const aSituer = etat.orphelines?.length || 0;
  const f = etat.filtreCarte;
  const amis = amisDeLaCarte();
  const nouveautes = nouveautesCarte();
  const nbNouvelles = etat.carte.filter((p) => !p.vue && !p.moi).length;
  const points = pointsCarteFiltres();
  const moi = etat.moi || { pseudo: '?' };

  const onglet = (v, texte) => `
    <button class="puce ${f.qui === v ? 'actif' : ''}" style="--c:var(--accent)"
            onclick="filtreQui('${v}')">${texte}</button>`;
  const coches = f.qui instanceof Set ? f.qui.size : 0;
  const nFiltres = combienDeFiltresCarte();
  // La même ligne que la galerie : « de qui » toujours sous la main, le reste
  // — règne, personnes précises, taille des bulles — dans le panneau.
  const filtres = `
    <div class="filtres-carte">
      <div class="entete-galerie">
        <div class="puces">
          ${onglet('tous', t('Tout'))}${onglet('moi', t('Moi'))}${onglet('amis', t('Amis'))}
          ${coches ? `<button class="puce actif" style="--c:var(--accent)"
            onclick="basculeFiltresCarte()">${t('{0} personne{1}', [coches, coches > 1 ? 's' : ''])}</button>` : ''}
        </div>
        <button class="puce ${nFiltres ? 'actif' : ''}" style="--c:var(--accent)"
                onclick="basculeFiltresCarte()">${t('Filtres{0}', [nFiltres ? ` · ${nFiltres}` : ''])}</button>
      </div>
      <div class="puces quoi">
        <button class="puce ${nouveautes ? 'actif' : ''}" style="--c:var(--alerte)"
                onclick="filtreNouveautes(true)">${t('✨ Nouveautés{0}', [nbNouvelles ? ` · ${nbNouvelles}` : ''])}</button>
        <button class="puce ${!nouveautes ? 'actif' : ''}" style="--c:var(--accent)"
                onclick="filtreNouveautes(false)">${t('Tout voir')}</button>
        ${amis.filter((a) => a.nouvelles).slice(0, 3).map((a) => `
          <button class="puce ami" style="--c:var(--alerte)" title="${t('{0} : {1} à voir', [echappe(a.pseudo), a.nouvelles])}"
                  onclick="basculeAmiCarte(${a.id})">${avatar(a, 20, false)}<i class="badge-neuf">${a.nouvelles}</i></button>`).join('')}
        ${aSituer ? `
          <button class="puce" style="--c:var(--alerte)"
                  onclick="va('asituer')">${t('📍 {0} à situer', [aSituer])}</button>` : ''}
      </div>
      ${etat.filtresCarteOuverts ? panneauFiltresCarte() : ''}
    </div>`;

  if (!etat.carte.length) {
    return filtres + messageVide(t('Aucune photo située'),
      t('Les photos avec un lieu apparaissent ici — les tiennes et celles de tes amis.'));
  }

  const mode = etat.modeCarte || 'plan';
  const fond = FONDS[fondCourant()];
  const suivant = Object.keys(FONDS)[(Object.keys(FONDS).indexOf(fondCourant()) + 1) % Object.keys(FONDS).length];
  const flottants = `
    <div class="flottants">
      <button onclick="changeFond('${suivant}')" title="${t('Fond : {0}', [fond.nom])}">🗺 ${fond.nom}</button>
      <button onclick="modeCarte('${mode === 'lieux' ? 'plan' : 'lieux'}')"
              title="${mode === 'lieux' ? 'Voir la carte' : t('Voir par lieu')}">
        ${mode === 'lieux' ? '📍 Carte' : t('☰ Par lieu')}</button>
    </div>`;

  // Rien dans ce filtre : on le dit à la place de la carte, avec la sortie.
  const vide = !points.length ? `
    <div class="carte-vide">
      <b>${nouveautes ? 'Rien de nouveau ici' : t('Rien ici')}</b>
      <span class="doux">${nouveautes
        ? t('Tu as tout vu chez tes amis — pour ce filtre en tout cas.')
        : t('Aucune photo ne correspond à ces filtres.')}</span>
      ${nouveautes ? `<button class="secondaire" onclick="filtreNouveautes(false)">${t('Tout voir')}</button>` : ''}
    </div>` : '';

  if (mode === 'lieux') {
    return filtres + `<div class="scene-carte liste">${flottants}${vide || vueParLieu(points)}</div>`;
  }

  // Le fil des nouveautés : les photos pas encore vues, les plus récentes
  // d'abord, en bandeau sur la carte. On touche, la carte vole dessus et la
  // photo s'ouvre. C'est le chemin court pour « qu'est-ce qu'ils ont posté ».
  const neuves = points.filter((p) => !p.vue && !p.moi).slice(0, 60);
  const fil = neuves.length ? `
    <div class="fil-nouveautes">
      <div class="defile">${neuves.map((p) => `
        <button class="nouveaute" onclick="voirSurCarte(${p.capture_id})"
                title="${echappe(`${p.nom || 'Photo'} — ${p.pseudo}`)}">
          <span class="photo" style="background-image:url('${image(p.vignette)}${
            p.vignette.includes('?') ? '&' : '?'}taille=160')"></span>
          ${avatar(p, 18, false)}
        </button>`).join('')}</div>
      <button class="lien tout-vu" onclick="marqueToutVu()">${t('✓ Tout vu')}</button>
    </div>` : '';

  return filtres + `
    <div class="scene-carte">
      <div id="carte"></div>
      ${flottants}
      ${vide}
      ${fil}
    </div>
    <p class="doux compte-carte">${t('{0} photo{1}{2}', [points.length, points.length > 1 ? 's' : '', 
      nbNouvelles && !nouveautes ? ` ${t('· {0} pas encore vue{1}', [nbNouvelles, nbNouvelles > 1 ? 's' : ''])}` : ''])}</p>`;
}

function modeCarte(m) {
  etat.modeCarte = m;
  dessine();
}

/* Ouvrir une photo depuis la carte.
 *
 * On note d'abord où l'on est — ou, mieux, où est la photo — parce que la
 * visionneuse redessine la page et la carte avec : sans ça, elle revenait au
 * cadrage initial à chaque fermeture, et on perdait l'endroit qu'on était en
 * train de fouiller. Et on marque la photo vue tout de suite : le serveur le
 * fait de son côté en servant le détail, le fil et les bulles n'ont pas à
 * attendre son retour. */
function voirSurCarte(id, suite = null) {
  const p = etat.carte.find((x) => x.capture_id === id);
  if (p) {
    p.vue = true;
    etat.carteVue = { centre: [p.lat, p.lon],
                      zoom: Math.max(etat.carteVue?.zoom || 0, 14) };
  }
  const voisins = suite || (p
    ? pointsCarteFiltres().filter((x) => !x.vue || x.capture_id === id).map((x) => x.capture_id)
    : null);
  ouvreVisionneuse(id, voisins && voisins.length > 1 ? voisins : null);
}

async function marqueToutVu() {
  const ids = pointsCarteFiltres().filter((p) => !p.vue && !p.moi).map((p) => p.capture_id);
  if (!ids.length) return;
  try {
    await appel('/captures/vues', { method: 'POST', body: { ids } });
    for (const p of etat.carte) if (ids.includes(p.capture_id)) p.vue = true;
    signale(`${t('{0} photo{1} marquée{2} vue{3}.', [ids.length, ids.length > 1 ? 's' : '', ids.length > 1 ? 's' : '', ids.length > 1 ? 's' : ''])}`);
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* Les photos regroupées par lieu, de la sortie la plus fournie à la plus
 * maigre. Dans chaque lieu, ce qu'on n'a pas vu passe devant. Les coordonnées
 * sans nom sont rassemblées à part : « 48.85, 2.35 » ne dit rien à personne,
 * mais « 12 photos sans lieu nommé » se comprend. */
function vueParLieu(points = pointsCarteFiltres()) {
  const par = new Map();
  for (const p of points) {
    const cle = (p.lieu || '').trim() || '\u0000sans';
    if (!par.has(cle)) par.set(cle, []);
    par.get(cle).push(p);
  }
  const groupes = [...par.entries()]
    .sort((a, b) => b[1].length - a[1].length);
  return `<div class="lieux">${groupes.map(([cle, photos]) => {
    const tri = [...photos].sort((a, b) => (a.vue - b.vue));
    const suite = tri.map((p) => p.capture_id);
    const neuves = photos.filter((p) => !p.vue && !p.moi).length;
    return `
    <section>
      <h3>${cle === '\u0000sans'
        ? `<span class="doux">${t('Sans lieu nommé')}</span>` : echappe(cle)}
        <span class="doux">· ${photos.length}</span>
        ${neuves ? `<i class="badge-neuf">${neuves}</i>` : ''}</h3>
      <div class="mur serre">${tri.slice(0, 18).map((p) => `
        <div class="tuile ${p.vue ? '' : 'neuve'}"
             onclick="voirSurCarte(${p.capture_id}, ${JSON.stringify(suite)})">
          <img src="${image(p.vignette)}${p.vignette.includes('?') ? '&' : '?'}taille=256" alt="" loading="lazy">
          ${avatar(p, 18, false)}
        </div>`).join('')}
      </div>
    </section>`; }).join('')}</div>`;
}

/* Les photos à situer, avec sélection multiple.
 *
 * Sur l'application, c'est l'écran atteint depuis la carte : on y coche
 * plusieurs photos d'une même sortie et on leur pose le même lieu d'un coup.
 * Le site ne savait pas le faire du tout. */
function vueASituer() {
  const l = etat.orphelines;
  if (l === null || l === undefined) { chargeOrphelines(); return Media.chargement(); }
  if (!l.length) {
    return messageVide(t('Tout est situé'), t('Aucune photo n\'attend un lieu.'));
  }
  const choisies = etat.aSituerChoisies;
  return `
    ${choisies.size ? `
      <div class="barre-selection">
        <button onclick="videSelectionSituer()">✕</button>
        <b>${t('{0} sélectionnée{1}', [choisies.size, choisies.size > 1 ? 's' : ''])}</b>
        <button class="primaire" onclick="situeChoisies()">${t('Situer')}</button>
      </div>` : `
      <div class="rangee-centree haut-page">
        <button class="lien" onclick="toutSelectionnerSituer()">${t('Tout sélectionner')}</button>
      </div>`}
    <ul class="a-situer">${l.map((c) => {
      const prise = choisies.has(c.capture_id);
      return `
      <li class="${prise ? 'prise' : ''}" onclick="basculeSituer(${c.capture_id})">
        <span class="coche">${prise ? '●' : '○'}</span>
        <img src="${image(c.vignette)}" alt="" loading="lazy">
        <span class="corps">
          <b>${echappe(c.nom || 'Sans espèce')}</b>
          <span class="manques">
            ${c.sans_position ? `<i>${t('sans lieu')}</i>` : ''}
            ${c.sans_heure ? `<i>${t('sans date')}</i>` : ''}
          </span>
        </span>
      </li>`; }).join('')}</ul>`;
}

async function chargeOrphelines() {
  try {
    const d = await appel('/carte/orphelines');
    etat.orphelines = d.captures;
  } catch (e) { etat.orphelines = []; signale(e.message, true); }
  dessine();
}

function basculeSituer(id) {
  const s = etat.aSituerChoisies;
  if (!s.delete(id)) s.add(id);
  dessine();
}
function videSelectionSituer() { etat.aSituerChoisies.clear(); dessine(); }
function toutSelectionnerSituer() {
  etat.orphelines.forEach((c) => etat.aSituerChoisies.add(c.capture_id));
  dessine();
}

/* Poser le même lieu et la même date sur tout le lot.
 *
 * On prend la position du navigateur une seule fois et on l'applique à toutes
 * les photos cochées — c'est le geste d'une sortie : on rentre, on situe les
 * douze photos de l'après-midi d'un coup.
 *
 * Ce que ça ne fait pas, et il faut le savoir : on ne peut pas désigner un
 * point sur la carte. Le site n'a pas d'écran de sélection au doigt, seulement
 * « ici et maintenant ». Pour poser un lieu où l'on n'est plus, il faut passer
 * par l'application.
 */
async function situeChoisies() {
  const ids = [...etat.aSituerChoisies];
  if (!ids.length) return;
  try {
    const p = await new Promise((ok, non) => {
      if (!navigator.geolocation) return non(new Error(t('Localisation indisponible.')));
      navigator.geolocation.getCurrentPosition(ok, () =>
        non(new Error(t('Position refusée. Autorise la localisation.'))),
        { timeout: 8000, enableHighAccuracy: true });
    });
    const corps = {
      lat: p.coords.latitude,
      lon: p.coords.longitude,
      prise_le: new Date().toISOString().slice(0, 19).replace('T', ' '),
    };
    // En série et non en parallèle : douze requêtes simultanées sur un serveur
    // sans GPU, pour douze écritures d'une ligne, ne gagnent rien et peuvent
    // se marcher dessus sur le fichier SQLite.
    let faites = 0;
    for (const id of ids) {
      await appel(`/captures/${id}/lieu`, { method: 'PATCH', body: corps });
      faites += 1;
    }
    etat.aSituerChoisies.clear();
    etat.orphelines = null;
    signale(`${t('{0} photo{1}.', [faites, faites > 1 ? 's situées' : t('située')])}`);
    chargeOrphelines();
  } catch (e) { signale(e.message, true); }
}

function vueCredits() {
  const c = etat.credits;
  if (!c) return Media.chargement();
  // Ils sont plusieurs centaines. Tout afficher d'un coup faisait une page de
  // deux cents kilo-octets que personne ne lit jusqu'au bout ; les vingt plus
  // gros contributeurs disent l'essentiel, le reste est à un clic.
  const tous = c.silhouettes || [];
  const silhouettes = etat.toutLesCredits ? tous : tous.slice(0, 20);
  return `<div class="centre" style="font-size:13.5px;line-height:1.6">
    <h3 class="titre" style="margin-left:0">${t('Les silhouettes')}</h3>
    <p class="doux">${t('Les dessins du dex viennent de PhyloPic et de ses contributeurs, sous licences libres. Merci à eux.')}</p>
    ${silhouettes.map((a) => `
      <div class="ligne" style="padding-left:0;padding-right:0">
        <span class="texte"><b>${echappe(a.auteur)}</b>
          <span class="doux">${echappe(licence(a.licence))}</span></span>
        <span class="doux">${a.images}</span>
      </div>`).join('')}
    ${tous.length > silhouettes.length ? `
      <button class="discret" onclick="etat.toutLesCredits=true;dessine()">
        ${t('Voir les {0} autres contributeurs', [tous.length - silhouettes.length])}</button>` : ''}
    <h3 class="titre" style="margin-left:0">${t('Les données')}</h3>
    <p class="doux">${t('Les espèces et leurs observations viennent de GBIF ; les fiches et les photos d\'illustration, de Wikipédia et Wikimedia Commons ; la reconnaissance, de Pl@ntNet et d\'iNaturalist.')}</p>
  </div>`;
}

/* Une licence lisible. Les URL Creative Commons se ressemblent toutes, et
 * personne ne lit « publicdomain/zero/1.0 » comme « domaine public ». */
function licence(url) {
  if (!url) return '';
  if (url.includes('publicdomain')) return t('Domaine public (CC0)');
  const m = url.match(/licenses\/([a-z-]+)\/([\d.]+)/);
  return m ? `${t('CC {0} {1}', [m[1].toUpperCase(), m[2]])}` : url;
}

/* ═══════════════════════════════ l'ossature ═══════════════════════════════ */

/* Les icônes de la barre, reprises des « Icons » de Material dont se sert
 * l'application : grid_view_rounded, people_rounded, photo_library_rounded,
 * person_rounded. */
const ICONES = {
  dex: 'M4 4h6.5v6.5H4zm9.5 0H20v6.5h-6.5zM4 13.5h6.5V20H4zm9.5 0H20V20h-6.5z',
  amis: 'M16 11a4 4 0 100-8 4 4 0 000 8zm-8 0a4 4 0 100-8 4 4 0 000 8zm0 2c-2.7 0-8 1.3-8 4v3h10v-3c0-1 .4-2 1.2-2.8-1-.1-2.2-.2-3.2-.2zm8 0c-.6 0-1.3 0-2 .1 1.2.9 2 2 2 3.2v3h8v-3c0-2.7-5.3-4-8-4z',
  galerie: 'M20 4H8a2 2 0 00-2 2v10a2 2 0 002 2h12a2 2 0 002-2V6a2 2 0 00-2-2zm-9.5 9.5l2.2 2.7 3.1-4 4 5.3H9l1.5-4zM4 8H2v12a2 2 0 002 2h12v-2H4V8z',
  profil: 'M12 12a5 5 0 100-10 5 5 0 000 10zm0 2c-3.3 0-10 1.7-10 5v3h20v-3c0-3.3-6.7-5-10-5z',
};

/* La sphère de capture, au trait, comme le `CustomPainter` du Dart : calotte
 * rouge, calotte claire, ceinture d'encre, bouton central et un reflet en haut
 * à gauche — sans lui elle paraît plate. Dessinée plutôt qu'importée, elle
 * reste nette à toutes les tailles. */
function sphere(taille = 62) {
  const r = 50 - 6;           // le rayon, dans un repère de 100
  const ep = r * 0.13;
  return `
    <svg class="sphere" width="${taille}" height="${taille}" viewBox="0 0 100 100">
      <defs><clipPath id="boule"><circle cx="50" cy="50" r="${r}"/></clipPath></defs>
      <path d="M ${50 - r} 50 A ${r} ${r} 0 0 1 ${50 + r} 50 Z" fill="#E84C4C"/>
      <path d="M ${50 + r} 50 A ${r} ${r} 0 0 1 ${50 - r} 50 Z" fill="#F7F7F8"/>
      <circle cx="${50 - r * 0.34}" cy="${50 - r * 0.40}" r="${r * 0.30}"
              fill="#fff" opacity=".34" clip-path="url(#boule)"/>
      <circle cx="50" cy="50" r="${r}" fill="none" stroke="#17181C"
              stroke-width="${ep * 0.8}"/>
      <line x1="${50 - r}" y1="50" x2="${50 + r}" y2="50"
            stroke="#17181C" stroke-width="${ep}"/>
      <circle cx="50" cy="50" r="${r * 0.30}" fill="#17181C"/>
      <circle cx="50" cy="50" r="${r * 0.21}" fill="#F7F7F8"
              stroke="#17181C" stroke-width="${ep * 0.45}"/>
    </svg>`;
}

const TITRES = {
  dex: t('Dex'), capture: t('Photographier'), amis: t('Amis'), galerie: t('Galerie'),
  profil: t('Profil'), paliers: t('Mes paliers'), mescaptures: t('Mes photos'),
  reglages: t('Réglages'),
  classement: t('Classement'), carte: t('Carte'), notifications: t('Notifications'),
  credits: t('Crédits'), vitrine: t('Mes succès'),
  mesespeces: t('Espèces indexées'),
  reglagesnotifs: t('Mes notifications'),
  asituer: t('Photos à situer'),
};

/* Quatre onglets et un bouton central, comme dans l'application : la sphère
 * n'est pas un onglet parmi cinq, c'est le geste qu'on vient faire. */
const ONGLETS = ['dex', 'amis', 'galerie', 'profil'];
const RATTACHE = {
  paliers: 'dex', carte: 'dex', mescaptures: 'profil', reglages: 'profil',
  classement: 'profil', credits: 'profil', notifications: 'amis',
  vitrine: 'dex', mesespeces: 'mescaptures', reglagesnotifs: 'notifications',
  asituer: 'carte',
  capture: null,
};

function barre() {
  const alertes = (etat.moi?.demandes || 0) + etat.nonLues;
  const onglet = (k, nom) => {
    const actif = etat.vue === k || RATTACHE[etat.vue] === k;
    const badge = k === 'amis' && alertes ? `<i class="compteur">${alertes}</i>` : '';
    return `<button class="${actif ? 'actif' : ''}" onclick="va('${k}')">
      <span class="ico">
        <svg viewBox="0 0 24 24"><path d="${ICONES[k]}"/></svg>${badge}
      </span>
      <span class="nom">${nom}</span>
    </button>`;
  };
  return `
    <nav>
      <!-- L'encoche est découpée dans la barre, pas dessinée par-dessus : la
           sphère doit paraître posée dedans, comme le CircularNotchedRectangle
           de l'application. -->
      <svg class="encoche" viewBox="0 0 100 20" preserveAspectRatio="none"
           aria-hidden="true"></svg>
      ${onglet('dex', t('Dex'))}
      ${onglet('amis', t('Amis'))}
      <span class="creux"></span>
      ${onglet('galerie', t('Galerie'))}
      ${onglet('profil', t('Profil'))}
    </nav>
    ${etat.vue === 'capture' ? '' : `
      <button class="flottant" onclick="va('capture')" aria-label="${t('Photographier')}">
        ${sphere()}
      </button>`}`;
}

const VUES = {
  dex: vueDex, capture: vueCapture, amis: vueAmis, galerie: vueGalerie,
  profil: vueProfil, paliers: vuePaliers, mescaptures: vueMesCaptures,
  reglages: vueReglages,
  classement: vueClassement, carte: vueCarte, credits: vueCredits,
  notifications: vueNotifications, vitrine: vueVitrine,
  mesespeces: vueMesEspeces, reglagesnotifs: vueReglagesNotifs,
  asituer: vueASituer,
};

const pileDeFiche = () => vueFiche() + vuePhotosDuLieu() + vueVisionneuse();

function dessine() {
  const app = document.getElementById('app');
  if (etat.vue === 'connexion') {
    app.innerHTML = vueConnexion();
    // La grenouille de l'accueil est un canevas comme les autres : sans ce
    // réveil, elle resterait figée sur sa première image.
    Media.reveille();
    return;
  }

  const parent = RATTACHE[etat.vue];
  // Le dex dessine son en-tête lui-même : titre, carte, filtres et recherche
  // sur une seule ligne. Les autres écrans reçoivent l'AppBar commune.
  const entete = etat.vue === 'dex' ? '' : `
    <header>
      ${parent ? `<button class="retour" onclick="va('${parent}')" aria-label="${t('Retour')}">
        <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor">
          <path d="M15.4 7.4L14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg></button>` : ''}
      <h1>${TITRES[etat.vue] || 'Biodex'}</h1>
      ${etat.vue === 'amis' ? `
        <button class="outil" onclick="va('notifications')" aria-label="${t('Notifications')}">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor">
            <path d="M12 22a2 2 0 002-2h-4a2 2 0 002 2zm6-6V11a6 6 0 00-5-5.9V4a1 1 0 10-2 0v1.1A6 6 0 006 11v5l-2 2v1h16v-1l-2-2z"/>
          </svg>
          ${etat.nonLues ? `<i class="compteur">${etat.nonLues}</i>` : ''}
        </button>` : ''}
    </header>`;

  app.innerHTML = `
    ${entete}
    <main>${(VUES[etat.vue] || vueDex)()}</main>
    ${barre()}
    <!-- Fiche, planche d'un lieu, visionneuse : dans cet ordre, parce qu'on
         ouvre la seconde depuis la première et la troisième depuis les deux.
         Rendue avant, la visionneuse s'ouvrait bel et bien et restait cachée
         dessous. Dans un même contexte d'empilement, c'est l'ordre du DOM qui
         décide. -->
    ${etat.dexJoueur ? '' : pileDeFiche()}
    ${vueJoueur()}
    <!-- Le dex d'un ami s'ouvre depuis son profil : il passe après lui, sinon
         le profil le recouvre et les cases ne répondent pas. Et la fiche qu'on
         ouvre depuis une de ses cases doit passer après lui encore : toute la
         pile remonte donc ici tant que la planche est ouverte. -->
    ${etat.dexJoueur ? vueDexJoueur() + pileDeFiche() : ''}
    ${etat.filtresOuverts ? vueFiltres() : ''}
    ${vueChoixEspece()}
    ${vueEditeur()}
    ${vueSortie()}
    ${vueIdentification()}
    ${vueApercu()}
    ${vueFicheSucces()}
    ${vueNouvelleEspece()}
    ${vueSituer()}
    ${vueChoixVitrine()}
    ${etat.charge && (etat.trouvees.length || etat.galerie.length)
      ? `<div class="attente-flottante">${Media.chargement(34)}</div>` : ''}
    ${etat.erreur ? `<div class="toast erreur-toast">${echappe(t(etat.erreur))}</div>` : ''}
    ${etat.info ? `<div class="toast">${echappe(t(etat.info))}</div>` : ''}`;

  if (etat.vue === 'carte') dessineCarte();
  if (etat.situer) dessineCarteSituer();
  if (etat.visionneuse) poseGlissement();
  poseLaSphere();
  Disposition.poseGestes();
  poseDefilementProfil();
  // Les pistes d'une analyse indéterminée méritent leurs illustrations autant
  // que la recherche : c'est là qu'il faut reconnaître la bête.
  const pistes = etat.captureEnCours?.top;
  if (pistes?.length) chargeApercusDe(pistes.map((x) => x.case_id));
  // Une fiche de succès obtenue montre un vrai rendu 3D. Le drapeau est relu à
  // chaque trame de rendu plutôt que posé aux deux ou trois endroits qui
  // ouvrent la fiche : un chemin oublié laisserait la page endormie.
  veillePourLa3D(!!(etat.succesOuvert && etat.succes?.succes
    .find((x) => x.cle === etat.succesOuvert)?.obtenu));
  poseAppuiLong();
  dessineTimbre();
  // Les canvas viennent d'être recréés par `innerHTML` : on relance leurs
  // boucles. Ceux d'avant se sont arrêtés seuls en quittant le document.
  Media.reveille();
  // `innerHTML` recrée la toile à chaque rendu, et une toile neuve est vide :
  // il faut la repeindre, sinon l'éditeur s'efface au moindre changement
  // d'outil.
  if (etat.editeur) { peintEditeur(); dessineCadreCoupe(); }
  joueLesEntrees();
  noteLaPosition();
}

/* ──────────────────────────────── animations ────────────────────────────
 *
 * Le site n'en avait aucune : on passait d'un écran à l'autre par un
 * remplacement brutal, sans que rien n'indique qu'on avait bougé.
 *
 * **La contrainte, et ce qu'elle impose.** `dessine()` remplace tout le
 * contenu de `#app` d'un bloc. Les transitions CSS, qui interpolent entre deux
 * états d'un même élément, n'ont donc aucune prise : l'élément d'avant n'existe
 * plus. Tout passe par des `@keyframes` d'apparition, qui se déclenchent à la
 * création — ce que `innerHTML` fait pour nous à chaque rendu.
 *
 * **Et le piège qui va avec.** Puisque tout est recréé, tout se ré-animerait à
 * chaque rendu : cocher un filtre relancerait l'apparition des cent vignettes
 * du dex. Insupportable. On ne pose donc la classe qu'aux moments où l'écran a
 * réellement changé — c'est le rôle des « clés » ci-dessous : une chaîne qui
 * décrit ce qui est affiché, et l'animation ne rejoue que si elle a bougé.
 */
const CLES_ANIM = new Map();

/* La cascade se suit à part : ce n'est pas « a-t-elle changé » mais « combien
 * en a-t-on déjà fait défiler », puisque les grilles se remplissent par pages. */
let cascadeVue = null;
let cascadeFaits = 0;

/* Rejoue-t-on l'animation de ce bloc ? Oui seulement si son identité a changé
 * depuis le dernier rendu. */
function aChange(nom, cle) {
  if (cle === null) { CLES_ANIM.delete(nom); return false; }
  if (CLES_ANIM.get(nom) === cle) return false;
  CLES_ANIM.set(nom, cle);
  return true;
}

function joueLesEntrees() {
  const app = document.getElementById('app');

  // L'écran principal : il glisse et se révèle au changement de vue.
  if (aChange('vue', etat.vue)) app.querySelector('main')?.classList.add('entre');

  // Les grilles arrivent en cascade — mais seulement les vignettes qui viennent
  // d'apparaître.
  //
  // Le piège : au changement d'écran, la grille est encore vide, les photos
  // arrivent une requête plus tard. Se contenter de « la vue a changé » ferait
  // donc animer une grille sans contenu, et jamais celle qu'on regarde. On
  // compte plutôt ce qui a déjà été animé, et on ne s'occupe que du reste :
  // la première page cascade, la deuxième aussi, et un simple redessin ne
  // relance rien.
  //
  // Le décalage passe par une variable CSS plutôt que par des `nth-child` :
  // on ne sait pas combien il y aura d'éléments. Plafonné à douze — au-delà,
  // le dernier arriverait après que le doigt a commencé à faire défiler, et
  // l'écran paraîtrait lent au lieu de vif.
  const vignettes = [...app.querySelectorAll(
    'main .mur > *, main .grille-dex > *, main .grille-succes > *')]
    // Les cases d'attente vont et viennent au fil du chargement : les compter
    // décalerait tout, et les animer ferait clignoter un vide.
    .filter((e) => !e.classList.contains('creuse'));

  if (cascadeVue !== etat.vue || vignettes.length < cascadeFaits) cascadeFaits = 0;
  cascadeVue = etat.vue;
  vignettes.slice(cascadeFaits).forEach((e, i) => {
    e.style.setProperty('--rang', Math.min(i, 12));
    e.classList.add('surgit');
  });
  cascadeFaits = vignettes.length;

  // Les panneaux qui se superposent. Chacun s'annonce par ce qu'il montre :
  // ouvrir la fiche d'une autre espèce rejoue l'animation, la redessiner non.
  const feuilles = [
    ['fiche', etat.fiche ? `c${etat.fiche.id}` : null, '.feuille-case'],
    ['visionneuse', etat.visionneuse ? `v${etat.visionneuse.id}` : null, '.feuille-photo'],
    ['succes', etat.succesOuvert ? `s${etat.succesOuvert}` : null, '.fiche-succes'],
  ];
  for (const [nom, cle, sel] of feuilles) {
    if (aChange(nom, cle)) app.querySelector(sel)?.classList.add('entre');
  }
  // Une seule clé pour toutes les modales : il n'y en a jamais deux à la fois,
  // et leur simple présence suffit à savoir s'il faut animer.
  const modale = app.querySelector('.modale:not(.fiche-succes)');
  if (aChange('modale', modale ? modale.className : null)) modale?.classList.add('entre');
}

/* Attirer l'oeil sur un élément qui vient de changer sans bouger de place —
 * typiquement le compteur de notifications, qui passait de 2 à 3 sans que
 * personne ne le remarque. */
function sursaute(selecteur) {
  const e = document.querySelector(selecteur);
  if (!e) return;
  e.classList.remove('sursaut');
  // Forcer un recalcul : sans lui, retirer puis remettre la classe dans la
  // même trame ne relance pas l'animation, le navigateur ne voit aucun
  // changement.
  void e.offsetWidth;
  e.classList.add('sursaut');
}

/* Le timbre de carte du résultat d'analyse.
 *
 * Un couple de coordonnées ne dit rien à personne ; un bout de plan dit tout
 * de suite si l'on est au bon endroit ou à trois départements de là. C'est là
 * que se repèrent les erreurs — la photo de vacances envoyée depuis le canapé.
 *
 * Inerte à dessein : sur une page qui défile, une carte manipulable happerait
 * le doigt à chaque passage. */
async function dessineTimbre() {
  // Tous, pas seulement le premier : une liste de photos à situer en montre
  // autant qu'elle a de lignes, et n'en peindre qu'un laisserait les autres
  // en carrés gris sans qu'on comprenne pourquoi.
  const cibles = [...document.querySelectorAll('.timbre')]
    .filter((c) => !c.dataset.peint);
  if (!cibles.length) return;
  await chargeLeaflet();
  if (!window.L) return;
  for (const cible of cibles) {
    // Le rendu a pu repartir pendant le chargement du script : la cible d'alors
    // n'est plus dans la page, et Leaflet planterait dessus.
    if (!document.body.contains(cible)) continue;
    cible.dataset.peint = '1';
    const lat = Number(cible.dataset.lat);
    const lon = Number(cible.dataset.lon);
    const doute = cible.dataset.doute === '1';
    const carte = L.map(cible, {
      zoomControl: false, attributionControl: false,
      dragging: false, scrollWheelZoom: false, doubleClickZoom: false,
      boxZoom: false, keyboard: false, touchZoom: false,
      // Assez serré pour reconnaître le quartier, assez large pour ne pas
      // donner à une supposition l'aplomb d'une mesure.
    }).setView([lat, lon], doute ? 10 : 13);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                { maxZoom: 19 }).addTo(carte);
    L.marker([lat, lon]).addTo(carte);
  }
}

/* ═══════════════════════════════ les actions ══════════════════════════════ */

async function connecte() {
  const pseudo = document.getElementById('pseudo').value.trim();
  const mdp = document.getElementById('mdp').value;
  etat.erreur = null;
  try {
    const r = await appel('/connexion', { method: 'POST', body: { pseudo, mdp } });
    garde(r.jeton);
    etat.vue = 'dex';
    await demarre();
  } catch (e) { etat.erreur = e.message; dessine(); }
}

async function inscrit() {
  const pseudo = document.getElementById('pseudo').value.trim();
  const mdp = document.getElementById('mdp').value;
  etat.erreur = null;
  try {
    const r = await appel('/inscription', { method: 'POST', body: { pseudo, mdp } });
    garde(r.jeton);
    etat.vue = 'dex';
    await demarre();
  } catch (e) { etat.erreur = e.message; dessine(); }
}

async function deconnecte() {
  try { await appel('/deconnexion', { method: 'POST' }); } catch (_) {}
  fermeLeFil();
  oublie();
  Object.assign(etat, { moi: null, trouvees: [], aTrouver: [], galerie: [], vue: 'connexion' });
  dessine();
}

async function chargeMoi() {
  try {
    etat.moi = await appel('/moi');
    const n = await appel('/notifications');
    etat.nonLues = n.non_lues || 0;
  } catch (_) {}
}

/* Au démarrage : si le bandeau retenu est la vitrine, on la charge tout de
 * suite, sinon l'écran s'ouvrirait sur le rang avant de basculer sous les yeux
 * du joueur. */
function reprendLaVitrine() {
  if (etat.bandeauVitrine && !etat.vitrine && !etat.chargeVitrine) {
    etat.chargeVitrine = true;
    chargeVitrine();
  }
}

async function chargeResume() {
  try { etat.resume = await appel('/dex/resume'); } catch (_) {}
}

/* Le dex ne pagine pas : il montre ce qu'on a, puis un échantillon de ce
 * qu'on peut trouver. Dérouler 977 415 silhouettes identiques n'a aucun
 * intérêt — c'est la règle de l'application, on la reprend telle quelle. */
const CASES_VIDES = 100;

const TRIS = {
  varie: t('Un peu de tout'),
  communes: t('Les plus communes'),
  rares: t('Les plus rares'),
  nom: t('Alphabétique'),
};

function filtresDex() {
  const f = {};
  if (etat.regne) f.regne = etat.regne;
  if (etat.classe) f.classe = etat.classe;
  if (etat.ordre) f.ordre = etat.ordre;
  if (etat.famille) f.famille = etat.famille;
  if (etat.qualite) f.rarete = etat.qualite;
  return f;
}

async function chargeDex() {
  etat.charge = true;
  dessine();
  const f = filtresDex();
  try {
    if (etat.mode === 'arbre') {
      const p = new URLSearchParams(f);
      if (etat.classe) p.set('classe', etat.classe);
      if (etat.ordre) p.set('ordre', etat.ordre);
      const a = await appel(`/dex/arbre?${p}`);
      etat.noeuds = a.noeuds || [];
      etat.niveau = a.niveau;
    } else if (etat.recherche) {
      // En recherche on fouille le catalogue entier, trouvé ou non : c'est le
      // seul cas où l'on veut voir ce qu'on n'a pas.
      const p = new URLSearchParams({ q: etat.recherche, limite: 120,
                                      tri: etat.tri, ...f });
      const d = await appel(`/dex?${p}`);
      etat.trouvees = d.cases || [];
      etat.aTrouver = [];
    } else if (etat.mode === 'recent') {
      const p = new URLSearchParams({ etat: 'decouvert', limite: 200,
                                      tri: 'recentes', ...f });
      etat.trouvees = (await appel(`/dex?${p}`)).cases || [];
      etat.aTrouver = [];
    } else {
      const [a, b] = await Promise.all([
        appel(`/dex?${new URLSearchParams({ etat: 'decouvert', limite: 300,
          tri: etat.tri === 'communes' ? 'recentes' : etat.tri, ...f })}`),
        // Les cases à trouver se panachent par défaut : c'est la vitrine du
        // dex, elle doit donner envie d'aller voir ailleurs que dans les
        // buissons à moineaux.
        appel(`/dex?${new URLSearchParams({ etat: 'manquant', limite: CASES_VIDES,
          tri: etat.tri === 'communes' ? 'varie' : etat.tri, ...f })}`),
      ]);
      etat.trouvees = a.cases || [];
      etat.aTrouver = b.cases || [];
    }
  } catch (e) { etat.erreur = e.message; }
  finally { etat.charge = false; dessine(); }
}

function changeMode(m) {
  etat.mode = m;
  if (m === 'arbre') { etat.classe = null; etat.ordre = null; etat.famille = null; }
  chargeDex();
}

/* Changer de règne remet la navigation taxonomique à zéro : une classe
 * d'oiseaux n'a aucun sens sous les plantes. */
function filtreRegne(cle) {
  if (etat.regne === cle) return;
  Object.assign(etat, { regne: cle, classe: null, ordre: null, famille: null });
  chargeDex();
}

function descend(nom) {
  if (!etat.classe) etat.classe = nom;
  else if (!etat.ordre) etat.ordre = nom;
  else { etat.famille = nom; etat.mode = 'collection'; }
  chargeDex();
}

function remonte(niveau) {
  if (niveau < 0) Object.assign(etat, { classe: null, ordre: null, famille: null });
  else if (niveau === 0) Object.assign(etat, { ordre: null, famille: null });
  else if (niveau === 1) etat.famille = null;
  etat.mode = 'arbre';
  chargeDex();
}

function ouvreFiltres() { etat.filtresOuverts = true; dessine(); }

function vueFiltres() {
  return `
    <div class="feuille" onclick="if(event.target===this)ferme('filtresOuverts')">
      <div class="corps">
        <div class="poignee"></div>
        <h2>${t('Filtrer et trier')}</h2>

        <h3 class="titre" style="margin-left:0">${t('Qualité')}</h3>
        <div class="puces">
          <button class="puce ${!etat.qualite ? 'actif' : ''}" style="--c:var(--accent)"
                  onclick="poseFiltre('qualite', null)">${t('Toutes')}</button>
          ${[1, 2, 3, 4, 5].map((q) => `
            <button class="puce ${etat.qualite === q ? 'actif' : ''}"
                    style="--c:var(--q${q})" onclick="poseFiltre('qualite', ${q})">
              ${QUALITES[q]}</button>`).join('')}
        </div>

        <h3 class="titre" style="margin-left:0">${t('Ordre')}</h3>
        <div class="menu choix">
          ${Object.entries(TRIS).map(([k, n]) => `
            <button class="${etat.tri === k ? 'coche' : ''}"
                    onclick="poseFiltre('tri', '${k}')">${n}</button>`).join('')}
        </div>

        <button class="principal" style="margin-top:18px"
                onclick="ferme('filtresOuverts')">${t('Voir les résultats')}</button>
      </div>
    </div>`;
}

function poseFiltre(cle, valeur) {
  etat[cle] = valeur;
  chargeDex();
}

let minuteur;
function cherche(v) {
  etat.recherche = v;
  // On attend que la frappe se calme : une requête par lettre ferait dix
  // appels pour un mot de dix lettres, et la plus lente écraserait la plus
  // récente.
  clearTimeout(minuteur);
  minuteur = setTimeout(chargeDex, 320);
}

/* Le règne choisi avant une photo. Il sert aussi de filtre au dex, mais
 * celui-ci passe par `filtreRegne`, qui remet la descente taxonomique à zéro. */
function filtre(cle, valeur) {
  etat[cle] = valeur;
  dessine();
}

async function ouvreFiche(id) {
  etat.fiche = [...etat.trouvees, ...etat.aTrouver].find((c) => c.id === id) || null;
  dessine();
  try {
    const [detail, fiche] = await Promise.all([
      appel(`/dex/${id}`),
      appel(`/dex/${id}/fiche`).catch(() => null),
    ]);
    // La fiche n'apporte que le texte encyclopédique et son illustration : ses
    // autres champs (`titre`, `case_id`) doubleraient ceux de la case avec des
    // valeurs venues de Wikipédia, qui n'est pas notre référence de nommage.
    const { resume, url, image: illustration, approximation } = fiche || {};
    etat.fiche = { ...etat.fiche, ...detail,
                   resume, url, image: illustration, approximation };
    dessine();
  } catch (_) {}
}

function ferme(quoi) {
  if (quoi === 'situer') carteSituer = null;
  // Fermer, c'est revenir en arrière. Passer par l'historique plutôt que par
  // l'état garde les deux d'accord : sans ça, le bouton « fermer » laisserait
  // une entrée derrière lui, et le geste de retour rouvrirait ce qu'on vient
  // de fermer.
  if (!retourEnCours && history.state?.couche === quoi) { history.back(); return; }
  etat[quoi] = null;
  dessine();
}

/* ───────────────────────────── photographier ───────────────────────────── */

/* L'étape entre le fichier choisi et l'analyse.
 *
 * Choisir une image la partait aussitôt au serveur : on découvrait le cadrage
 * en même temps que le verdict, et le règne — qui décide du moteur — se
 * choisissait *avant* d'avoir vu la photo, donc au hasard. Ici on regarde ce
 * qu'on envoie, on corrige le règne si c'est une plante et non une bête, puis
 * on envoie.
 *
 * L'aperçu vient d'une URL d'objet, jamais du serveur : la photo n'a pas
 * encore quitté le téléphone. On la libère à l'envoi comme à l'abandon, sinon
 * chaque essai laisserait une image entière en mémoire.
 */
function preparePhoto(entree) {
  const fichier = entree.files?.[0];
  if (!fichier) return;
  if (etat.preparation?.apercu) URL.revokeObjectURL(etat.preparation.apercu);
  etat.preparation = {
    fichier,
    apercu: URL.createObjectURL(fichier),
    regne: etat.regne || 'animal',
  };
  entree.value = '';   // pour que rechoisir le même fichier redéclenche
  dessine();
}

function regnePreparation(cle) {
  if (!etat.preparation) return;
  etat.preparation.regne = cle;
  // Le règne choisi ici devient celui par défaut de la prochaine photo : on
  // photographie rarement une plante entre deux oiseaux.
  etat.regne = cle;
  dessine();
}

/* Ouvrir l'éditeur sur la photo qu'on s'apprête à envoyer. */
function detoureAvantEnvoi() {
  if (etat.preparation) ouvreEditeur(null, etat.preparation.apercu);
}

function abandonnePreparation() {
  if (etat.preparation?.apercu) URL.revokeObjectURL(etat.preparation.apercu);
  etat.preparation = null;
  dessine();
}

function vuePreparation() {
  const p = etat.preparation;
  return `
    <div class="depot">
      <img class="grande" src="${p.apercu}" alt=""
           style="width:100%;border-radius:16px;margin-bottom:12px">
      <label class="titre-champ">${t('Quel règne ?')}</label>
      <div class="puces regnes-capture">
        ${REGNES_APP.map((r) => `
          <button class="puce ${p.regne === r.cle ? 'actif' : ''}"
                  style="--c:${r.couleur}"
                  onclick="regnePreparation('${r.cle}')">${r.emoji} ${r.nom}</button>`).join('')}
      </div>
      <p class="doux" style="text-align:center;font-size:12.5px;margin-top:8px">
        ${t('C\'est lui qui décide du moteur d\'analyse.')}</p>
      <button class="secondaire" style="width:100%;margin-top:12px"
              onclick="detoureAvantEnvoi()">
        ${p.decoupe ? '✂ Détourage prêt — refaire' : t('✂ Redresser et détourer')}</button>
      <button class="principal" style="width:100%;margin-top:14px"
              ${p.envoi ? 'disabled' : ''}
              onclick="envoieLaPreparation()">
        ${p.envoi ? 'Envoi…' : t('🔍 Lancer l\'analyse')}</button>
      <label class="zone" style="margin-top:10px;padding:12px">
        <input type="file" accept="image/*" onchange="preparePhoto(this)" hidden>
        <span class="doux">${t('Choisir une autre image')}</span>
      </label>
      <button class="discret" style="width:100%;margin-top:8px"
              onclick="abandonnePreparation()">${t('Annuler')}</button>
    </div>`;
}

async function envoieLaPreparation() {
  const p = etat.preparation;
  if (!p || p.envoi) return;
  p.envoi = true;
  dessine();
  const entree = { files: [p.fichier], regne: p.regne };
  await envoiePhoto(entree, p.regne, p.decoupe || null);
  if (etat.preparation) {
    URL.revokeObjectURL(etat.preparation.apercu);
    etat.preparation = null;
  }
}

async function envoiePhoto(entree, regne = null, decoupe = null) {
  const fichier = entree.files?.[0];
  if (!fichier) return;
  const forme = new FormData();
  forme.append('photo', fichier);
  forme.append('regne', regne || etat.regne || 'animal');
  forme.append('partage', 'true');
  // Le tracé fait avant l'envoi, s'il y en a un : le serveur l'accepte dès la
  // création et s'en sert à la place de son détourage automatique.
  if (decoupe) forme.append('decoupe', decoupe, 'decoupe.png');

  /* Le navigateur ne dit pas si la photo sort de l'appareil ou de la
   * pellicule, et rien dans le fichier ne tranche — d'autant que le champ ne
   * force plus la caméra, justement pour laisser le choix. On se rabat sur sa
   * date de
   * modification — un cliché pris à l'instant est vieux de quelques secondes,
   * une photo de vacances de plusieurs jours.
   *
   * L'heuristique se trompe dans un sens sans dommage : au pire une photo
   * fraîche est traitée comme ancienne, et l'application propose de confirmer
   * le lieu. L'inverse — affirmer qu'une vieille photo a été prise ici —
   * serait un mensonge, et c'est celui-là qu'on évite. */
  const age = Date.now() - (fichier.lastModified || 0);
  forme.append('instantanee', age < 5 * 60 * 1000 ? 'true' : 'false');

  // La position, si le navigateur veut bien la donner. On n'attend pas
  // indéfiniment : la photo prime, et le serveur lit de toute façon l'EXIF,
  // qui est plus fiable que la position du moment.
  try {
    const p = await new Promise((ok, non) => {
      if (!navigator.geolocation) return non();
      navigator.geolocation.getCurrentPosition(ok, non,
        { timeout: 5000, maximumAge: 60000, enableHighAccuracy: false });
    });
    forme.append('lat', p.coords.latitude);
    forme.append('lon', p.coords.longitude);
  } catch (_) { /* sans position, la capture marche très bien */ }

  try {
    const r = await appel('/captures', { method: 'POST', body: forme });
    etat.captureEnCours = r;
    dessine();
    suitAnalyse(r.id);
  } catch (e) { signale(e.message, true); }
}

/* Le suivi de l'analyse.
 *
 * Le serveur répond 202 : la photo est acceptée, le verdict viendra. On
 * interroge donc jusqu'à ce que l'état change, en espaçant les demandes —
 * une analyse prend une dizaine de secondes, marteler n'accélère rien. */
async function suitAnalyse(id, essai = 0) {
  if (essai > 60) return;
  await new Promise((r) => setTimeout(r, essai < 5 ? 1200 : 2500));
  try {
    const c = await appel(`/captures/${id}`);
    const avant = etat.captureEnCours;
    etat.captureEnCours = c;

    if (c.etat === 'attente' || c.etat === 'analyse') {
      // On ne redessine que si quelque chose a bougé pour le joueur — sa place
      // dans la file. `dessine()` remplace toute la page : à chaque appel le
      // canevas est recréé et le lancer repartirait de zéro, sans jamais
      // dépasser la visée. Ne rien redessiner, c'est aussi trois trames de
      // travail en moins toutes les deux secondes.
      if (c.position_file !== avant?.position_file) dessine();
      return suitAnalyse(id, essai + 1);
    }

    // Le verdict est là. La sphère le joue avant que la fiche prenne la place :
    // remplacer l'écran tout de suite escamoterait la seule scène qu'on attend.
    chargeResume();
    if (etat.vue === 'dex') chargeDex();
    if (sphereEnCours) sphereEnCours.termine(!!c.case_id);
    else dessine();
    // Après la sphère, pas pendant : deux animations à la fois se mangent.
    if (c.case_id) setTimeout(() => feteSiNouvelle(c.case_id), 1200);
  } catch (_) { dessine(); }
}

/* Les confettis, mais seulement pour une espèce qu'on n'avait pas.
 *
 * Le serveur ne dit pas « c'est une découverte » : il rend la case, et le
 * compte de photos qu'on y a rangées. Une seule, c'est la première — donc la
 * découverte. Même critère que l'application, et il vaut mieux le partager que
 * d'inventer un champ de plus.
 *
 * Fêter chaque photo viderait les confettis de leur sens : au dixième pigeon,
 * plus personne ne lève les yeux. */
async function feteSiNouvelle(caseId) {
  try {
    const d = await appel(`/dex/${caseId}`);
    if ((d.nb_captures || 0) > 1) { signale(t('Espèce enregistrée.')); return; }
    if (!reglage('confettis', true)) { signale(t('Nouvelle espèce !')); return; }
    Fete.fete(d.rarete || 1, d.nom_fr || d.latin || '');
  } catch (_) { signale(t('Espèce enregistrée.')); }
}

/* Le lancer de sphère qui tourne, s'il y en a un.
 *
 * Il vit hors du cycle de rendu : `dessine()` recrée le canevas, et une
 * animation redémarrée à chaque trame de rendu ne dépasserait jamais sa
 * première demi-seconde. */
let sphereEnCours = null;

function poseLaSphere() {
  const toile = document.querySelector('canvas[data-role="sphere"]');
  if (!toile) {
    // L'écran a changé : plus rien à animer.
    sphereEnCours?.arrete();
    sphereEnCours = null;
    return;
  }
  if (toile.dataset.lance) return;
  toile.dataset.lance = 'oui';
  sphereEnCours?.arrete();
  if (!reglage('lancer', true)) return;
  sphereEnCours = Sphere.lance(toile, {
    couleur: (REGNES_APP.find((r) => r.cle === (etat.regne || 'animal')) || {}).couleur
             || '#3fae5a',
    // La scène finale est jouée : on peut montrer le résultat.
    surFin: () => { sphereEnCours = null; dessine(); },
  });
}

function nouvellePhoto() { etat.captureEnCours = null; dessine(); chargeEnAttente(); }

/* Fermer une couche. Les feuilles et les modales passent toutes par ici. */

/* Rouvre une photo restée sans espèce, pour trancher. */
async function reprend(id) {
  try {
    etat.captureEnCours = await appel(`/captures/${id}`);
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* `caseId` à `null` détache la photo de toute espèce — c'est la marche
 * arrière sur une reconnaissance qu'on a acceptée trop vite. */
async function choisitEspece(captureId, caseId) {
  if (caseId === undefined) return;
  try {
    const c = await appel(`/captures/${captureId}/espece`,
                          { method: 'POST', body: { case_id: caseId } });
    etat.captureEnCours = c;
    if (caseId) feteSiNouvelle(caseId);
    else signale(t('Photo détachée.'));
    chargeResume();
    chargeEnAttente();
    // Le dex et la galerie viennent de changer sous nos pieds : on les vide
    // pour qu'ils se rechargent à la prochaine visite plutôt que d'afficher
    // une case encore grise.
    Object.assign(etat, { trouvees: [], aTrouver: [],
                          galerie: [], galerieDepuis: 0, galerieFin: false });
  } catch (e) { signale(e.message, true); }
}

async function chargeEnAttente() {
  try {
    const r = await appel('/captures/non-identifiees');
    etat.enAttente = r.captures || [];
    etat.joursAvantPurge = r.jours_avant_purge;
    dessine();
  } catch (_) { etat.enAttente = []; }
}

/* ───────────────────────────────── galerie ───────────────────────────────── */

/* Les filtres, traduits pour le serveur.
 *
 * Deux pièges tenus ici plutôt que dispersés dans l'écran :
 *
 * — `decalage`, pas `depuis`. Sur cette route `depuis` est une date, et lui
 *   passer un entier renvoie n'importe quoi sans erreur.
 * — les booléens à trois états. `situees=false` veut dire « seulement celles
 *   qui n'ont pas de lieu » ; ne pas envoyer le paramètre veut dire « les
 *   deux ». Un `false` envoyé par défaut viderait la galerie.
 */
function parametresGalerie() {
  const f = etat.fg;
  const p = new URLSearchParams({
    decalage: etat.galerieDepuis, limite: 40, tri: f.tri,
  });
  if (f.qui !== 'tous') p.set('qui', f.qui);
  if (f.regne) p.set('regne', f.regne);
  if (f.qualite) p.set('qualite', f.qualite);
  if (f.favoris) p.set('favoris', 'true');
  if (f.lieu) p.set('lieu', f.lieu);
  if (f.espece) p.set('espece', f.espece);
  if (f.depuis) p.set('depuis', f.depuis);
  if (f.jusqua) p.set('jusqua', f.jusqua);
  // Trois états, pas deux : `situees=false` veut dire « seulement celles qui
  // n'ont pas de lieu », et ne pas envoyer le paramètre veut dire « les deux ».
  // Un `false` envoyé par défaut viderait la galerie.
  if (f.sansLieu) p.set('situees', 'false');
  if (f.sansDate) p.set('datees', 'false');
  return p.toString();
}

/* Combien de filtres sont actifs — le chiffre affiché sur le bouton. Le tri
 * n'en est pas un : il ne cache aucune photo. */
function combienDeFiltres() {
  const f = etat.fg;
  return ['qui', 'regne', 'qualite', 'favoris', 'sansLieu', 'sansDate', 'lieu',
          'espece', 'depuis', 'jusqua'].filter((c) => f[c] !== FILTRES_VIDES[c]).length;
}

/* Les auteurs cochés, lus depuis `qui`. Une seule source : un second champ
 * qui dirait la même chose finirait par la dire autrement. */
function amisChoisis() {
  return etat.fg.qui.split(',').filter((x) => /^\d+$/.test(x)).map(Number);
}

function amiCoche(id) { return amisChoisis().includes(id); }

function basculeAmi(id) {
  const l = amisChoisis();
  const i = l.indexOf(id);
  if (i >= 0) l.splice(i, 1); else l.push(id);
  // Plus personne de coché : on revient à « tout », qui est l'état neutre —
  // une liste vide ne voudrait rien dire pour le serveur.
  changeFiltre('qui', l.length ? l.join(',') : 'tous');
}

function changeFiltre(cle, valeur) {
  etat.fg[cle] = valeur;
  chargeGalerie(true);
}

function videFiltres() {
  etat.fg = { ...FILTRES_VIDES };
  chargeGalerie(true);
}

function basculeFiltresGalerie() {
  etat.filtresGalerieOuverts = !etat.filtresGalerieOuverts;
  dessine();
  // Les menus se remplissent avec ce que le joueur possède réellement :
  // proposer « Champignon » à quelqu'un qui n'en a pas est une impasse.
  if (etat.filtresGalerieOuverts && !etat.reperes) chargeReperes();
}

async function chargeReperes() {
  try {
    etat.reperes = await appel('/galerie/reperes');
    dessine();
  } catch (_) { /* les menus resteront courts, l'écran marche quand même */ }
}

/* Chaque remise à zéro incrémente ce compteur. Une réponse qui revient avec un
 * numéro périmé est jetée : sans ça, changer de filtre pendant un chargement
 * ferait atterrir l'ancienne page dans la nouvelle liste, mélangée. */
let generationGalerie = 0;

async function chargeGalerie(remise = false) {
  // La garde ne vaut que pour la pagination. Un changement de filtre doit
  // toujours passer : le refuser laisserait à l'écran une liste qui ne
  // correspond plus à ce qui est coché.
  if (etat.charge && !remise) return;
  if (remise) {
    generationGalerie++;
    Object.assign(etat, { galerie: [], galerieDepuis: 0, galerieFin: false });
  }
  if (etat.galerieFin) return;
  const mienne = generationGalerie;
  etat.charge = true;
  dessine();
  try {
    const r = await appel(`/galerie?${parametresGalerie()}`);
    if (mienne !== generationGalerie) return;
    const photos = r.photos || [];
    etat.galerie = etat.galerie.concat(photos);
    etat.galerieDepuis += photos.length;
    etat.galerieFin = r.fin;
  } catch (e) {
    if (mienne === generationGalerie) etat.erreur = e.message;
  } finally {
    if (mienne === generationGalerie) { etat.charge = false; dessine(); }
  }
}

/* La suite dans laquelle on navigue, et le rang qu'on y occupe.
 *
 * L'application fait défiler les photos du doigt sans repasser par la grille ;
 * le site obligeait à refermer et rouvrir pour chacune. La suite dépend d'où
 * l'on vient : la galerie, ou les photos rangées dans une case. On la retient
 * à l'ouverture plutôt que de la deviner, parce que les deux listes existent en
 * même temps et qu'on ne saurait pas laquelle choisir après coup. */
function suiteDeLaVisionneuse() {
  return etat.suiteVisionneuse || [];
}

function rangDansLaSuite() {
  return suiteDeLaVisionneuse().indexOf(etat.visionneuse?.id);
}

/* `pas` vaut -1 ou +1. Rien au-delà des bords : on ne boucle pas, la fin d'une
 * liste doit se sentir. */
function glisseVisionneuse(pas) {
  const suite = suiteDeLaVisionneuse();
  const i = rangDansLaSuite();
  if (i < 0) return;
  const cible = suite[i + pas];
  if (cible != null) ouvreVisionneuse(cible, suite);
}

/* Le glissement horizontal, sur la photo. Vertical, on laisse défiler : la
 * fiche est plus haute que l'écran, et confisquer le défilement rendrait le
 * bas inatteignable. */
/* Le balayage et le zoom de la photo, dans la même fonction.
 *
 * Les deux gestes vivent sur le même élément et se disputeraient le doigt si
 * on les posait séparément : un pincement commence toujours par un contact, et
 * un déplacement à photo agrandie ressemble à un balayage. Ils se partagent
 * donc un seul état.
 *
 * La règle qui les sépare est simple et tient au nombre de doigts : deux
 * doigts ne veulent jamais dire « photo suivante ». Et une fois la photo
 * agrandie, un doigt la déplace au lieu de changer d'image — sinon on ne
 * pourrait pas atteindre les bords de ce qu'on vient d'agrandir.
 *
 * Le zoom manquait entièrement au site, là où l'application l'a partout : on
 * ne pouvait pas regarder de près l'insecte qu'on venait de photographier. */
function poseGlissement() {
  const img = document.querySelector('.feuille-photo img.grande');
  if (!img || img.dataset.glissement) return;
  img.dataset.glissement = 'oui';

  const MAX = 4;
  let echelle = 1;
  let tx = 0;
  let ty = 0;
  let x0 = null;
  let y0 = null;
  let pince = 0;          // distance entre les deux doigts au départ
  let echelle0 = 1;
  let dernierAppui = 0;

  function applique() {
    img.style.transformOrigin = 'center center';
    img.style.transform = `translate(${tx}px, ${ty}px) scale(${echelle})`;
    // Agrandie, la photo prend le geste : sans cela le navigateur défile la
    // page dès qu'on essaie de la déplacer. Au repos on lui rend le
    // défilement vertical, qui n'appartient pas à la photo.
    img.style.touchAction = echelle > 1 ? 'none' : 'pan-y';
    img.style.cursor = echelle > 1 ? 'grab' : '';
  }

  function remetAPlat() {
    echelle = 1; tx = 0; ty = 0;
    applique();
  }
  // Changer de photo remet le zoom à plat : garder l'agrandissement d'une
  // image sur la suivante cadrerait la nouvelle n'importe où.
  img.dataset.remiseZoom = 'oui';
  img.addEventListener('load', remetAPlat);

  function basculeZoom() {
    if (echelle > 1) remetAPlat();
    else { echelle = 2.5; tx = 0; ty = 0; applique(); }
  }

  img.addEventListener('dblclick', (e) => { e.preventDefault(); basculeZoom(); });

  img.addEventListener('touchstart', (e) => {
    if (e.touches.length === 2) {
      const a = e.touches[0];
      const b = e.touches[1];
      pince = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      echelle0 = echelle;
      x0 = null;
      return;
    }
    // Double tape : deux contacts rapprochés au même endroit.
    const t = Date.now();
    if (t - dernierAppui < 300) { basculeZoom(); dernierAppui = 0; x0 = null; return; }
    dernierAppui = t;
    x0 = e.touches[0].clientX;
    y0 = e.touches[0].clientY;
  }, { passive: true });

  img.addEventListener('touchmove', (e) => {
    if (e.touches.length === 2 && pince) {
      const a = e.touches[0];
      const b = e.touches[1];
      const d = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      echelle = Math.max(1, Math.min(MAX, echelle0 * (d / pince)));
      if (echelle === 1) { tx = 0; ty = 0; }
      applique();
      e.preventDefault();
      return;
    }
    if (echelle > 1 && x0 != null && e.touches.length === 1) {
      tx += e.touches[0].clientX - x0;
      ty += e.touches[0].clientY - y0;
      x0 = e.touches[0].clientX;
      y0 = e.touches[0].clientY;
      applique();
      e.preventDefault();
    }
  }, { passive: false });

  img.addEventListener('touchend', (e) => {
    if (pince) {
      // On sort d'un pincement : le doigt restant ne doit pas être pris pour
      // un balayage commencé.
      if (e.touches.length === 0) pince = 0;
      x0 = null;
      return;
    }
    if (x0 == null || echelle > 1) { x0 = null; return; }
    const dx = e.changedTouches[0].clientX - x0;
    const dy = e.changedTouches[0].clientY - y0;
    x0 = null;
    // Deux conditions : assez ample pour ne pas déclencher sur un appui, et
    // plus horizontal que vertical pour ne pas voler un début de défilement.
    if (Math.abs(dx) < 55 || Math.abs(dx) < Math.abs(dy)) return;
    glisseVisionneuse(dx < 0 ? 1 : -1);
  }, { passive: true });

  applique();
}

async function ouvreVisionneuse(id, suite = null) {
  try {
    // La suite par défaut : la galerie si la photo en fait partie. Sinon on
    // garde celle qu'on nous donne — les photos d'une case, par exemple.
    if (suite) etat.suiteVisionneuse = suite;
    else if (etat.galerie.some((p) => p.capture_id === id)) {
      etat.suiteVisionneuse = etat.galerie.map((p) => p.capture_id);
    } else etat.suiteVisionneuse = [id];

    etat.visionneuse = await appel(`/captures/${id}`);
    // Le favori n'est pas dans le détail d'une capture : on le lit dans la
    // ligne de galerie déjà chargée, quand elle existe.
    const ligne = etat.galerie.find((p) => p.capture_id === id);
    etat.favori = ligne ? !!ligne.favori : false;
    etat.reactions = {};
    dessine();
    etat.reactions = await appel(`/captures/${id}/reactions`).catch(() => ({}));
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* Une réaction se retire en la reposant : le même bouton fait les deux, comme
 * dans l'application. */
async function reagit(id, valeur) {
  const deja = etat.reactions?.ma_reaction === valeur;
  try {
    if (deja) await appel(`/captures/${id}/reaction`, { method: 'DELETE' });
    else await appel(`/captures/${id}/reaction`, { method: 'PUT', body: { valeur } });
    etat.reactions = await appel(`/captures/${id}/reactions`);
    dessine();
  } catch (e) { signale(e.message, true); }
}

async function basculeFavori(id) {
  const etait = etat.favori;
  try {
    await appel(`/captures/${id}/favori`, { method: etait ? 'DELETE' : 'PUT' });
    etat.favori = !etait;
    const ligne = etat.galerie.find((p) => p.capture_id === id);
    if (ligne) ligne.favori = etat.favori;
    dessine();
  } catch (e) { signale(e.message, true); }
}

async function changeTitre(id, titre) {
  try {
    await appel(`/captures/${id}/titre`, { method: 'PATCH', body: { titre } });
    if (etat.visionneuse?.id === id) etat.visionneuse.titre = titre;
    signale(t('Légende enregistrée.'));
  } catch (e) { signale(e.message, true); }
}

async function metVedette(caseId, captureId) {
  try {
    await appel(`/dex/${caseId}/vedette/${captureId}`, { method: 'POST' });
    signale(t('Photo mise en avant.'));
    // La case change d'image : la fiche ouverte et la grille du dex montrent
    // encore l'ancienne.
    if (etat.fiche?.id === caseId) {
      etat.fiche = await appel(`/dex/${caseId}`).catch(() => etat.fiche);
    }
    Object.assign(etat, { trouvees: [], aTrouver: [] });
    dessine();
    if (etat.vue === 'dex') chargeDex();
  } catch (e) { signale(e.message, true); }
}

async function supprimeCapture(id) {
  if (!confirm(t('Supprimer cette photo ? Cette action est définitive.'))) return;
  try {
    await appel(`/captures/${id}`, { method: 'DELETE' });
    etat.visionneuse = null;
    etat.galerie = etat.galerie.filter((p) => p.capture_id !== id);
    etat.mesCaptures = etat.mesCaptures.filter((c) => c.id !== id);
    chargeResume();
    signale(t('Photo supprimée.'));
  } catch (e) { signale(e.message, true); }
}

/* ────────────────────────────────── amis ────────────────────────────────── */

async function chargeAmis() {
  try {
    const [a, d] = await Promise.all([
      appel('/amis'), appel('/amis/demandes').catch(() => ({ recues: [] })),
    ]);
    etat.amis = a.amis || [];
    etat.demandes = d.recues || [];
  } catch (e) { etat.erreur = e.message; }
  dessine();
}

let minuteurAmis;
function chercheAmis(q) {
  clearTimeout(minuteurAmis);
  if (!q.trim()) { etat.rechercheAmis = []; dessine(); return; }
  minuteurAmis = setTimeout(async () => {
    try {
      const r = await appel(`/utilisateurs?q=${encodeURIComponent(q)}&limite=25`);
      etat.rechercheAmis = r.utilisateurs || [];
      dessine();
    } catch (_) {}
  }, 320);
}

/* La demande part sur le **pseudo**, pas sur l'identifiant : c'est ce que
 * l'API attend, et c'est aussi la seule chose qu'un joueur sait taper. */
async function demandeAmi(pseudo) {
  try {
    await appel('/amis/demandes', { method: 'POST', body: { pseudo } });
    signale(t('Demande envoyée.'));
    chargeAmis();
  } catch (e) { signale(e.message, true); }
}

/* `reponse` vaut « accepter » ou « refuser » — l'API refuse tout le reste. */
async function repondDemande(id, reponse) {
  try {
    await appel(`/amis/demandes/${id}/${reponse}`, { method: 'POST' });
    chargeAmis();
  } catch (e) { signale(e.message, true); }
}

async function ouvreJoueur(id) {
  try {
    etat.joueur = await appel(`/utilisateurs/${id}`);
    etat.detailJoueur = null;
    etat.trouvaillesJoueur = null;
    dessine();
    // D'où viennent ses points, et ce qu'il a trouvé de plus beau. En second :
    // le profil suffit à ouvrir l'écran, et faire attendre les deux pour n'en
    // montrer qu'un plus tard serait une lenteur gratuite.
    etat.detailJoueur = await appel(`/classement/joueur/${id}`).catch(() => null);
    if (etat.joueur?.id === id) dessine();
  } catch (e) { signale(e.message, true); }
}

/* La provenance des points, en barres.
 *
 * Une barre par qualité, proportionnelle au nombre de prises : on voit d'un
 * coup si quelqu'un accumule du commun ou s'il chasse le rare. Le total seul
 * ne dit pas ça — deux joueurs à six cents points peuvent avoir joué de façon
 * opposée. */
function detailDesPoints(d) {
  if (!d) return '';
  const max = Math.max(1, ...(d.par_qualite || []).map((q) => q.cases));
  return `
    <h3 class="titre">${t('D\'où viennent ses points')}</h3>
    <div class="qualites">
      ${(d.par_qualite || []).map((q) => `
        <div class="rangee-qualite">
          <span class="etiquette" style="--c:var(--q${q.qualite})">${echappe(q.nom)}</span>
          <span class="piste"><i style="width:${Math.round(q.cases / max * 100)}%;
            background:var(--q${q.qualite})"></i></span>
          <span class="doux">${t('{0} · {1} pt', [q.cases, q.points])}</span>
        </div>`).join('')}
    </div>
    <p class="doux" style="font-size:12.5px">
      ${t('{0} point(s) d\'espèces{1}{2}', [d.points_especes, 
        d.points_reactions ? ` ${t('· {0} de réactions', [d.points_reactions])}` : '', 
        d.photos != null ? ` ${t('· {0} photo(s)', [d.photos])}` : ''])}</p>`;
}

/* Les plus belles prises : une rangée qui défile, pas un mur. Au-delà de
 * quatre ou cinq, un mur repousserait le reste de la fiche hors de l'écran. */
function bellesPrises(liste, titre) {
  if (!liste?.length) return '';
  return `
    <h3 class="titre">${titre}</h3>
    <div class="rangee-prises">
      ${liste.map((m) => `
        <button class="prise" onclick="ferme('joueur');ouvreFiche(${m.case_id})"
                title="${echappe(m.nom)}">
          <img src="${image(photoDePiece(m))}" alt="" loading="lazy">
          <span class="gemme q${m.qualite}"></span>
          <span class="nom">${echappe(m.nom)}</span>
          ${m.pseudo && !m.moi ? `<span class="doux">${echappe(m.pseudo)}</span>` : ''}
        </button>`).join('')}
    </div>`;
}

/* La vitrine d'un profil : les photos qu'on a choisi de montrer.
 *
 * Le classement dit ce qu'on a trouvé de plus rare, la galerie tout ce qu'on a
 * pris. Ni l'un ni l'autre ne dit ce dont on est fier : la photo réussie d'un
 * moineau ne vaut aucun point et vaut pourtant qu'on la montre. */
function vitrineDuProfil(j) {
  const v = j.vitrine || [];
  const moi = etat.moi && j.id === etat.moi.id;
  if (!v.length) {
    return moi ? `
      <div class="bloc-profil">
        <h3 class="titre">${t('Ma vitrine')}</h3>
        <p class="doux" style="font-size:12.5px">
          ${t('Choisis jusqu\'à {0} photos à mettre en avant.', [j.vitrine_max || 6])}</p>
        <button class="secondaire" onclick="ouvreChoixVitrine()">${t('Composer ma vitrine')}</button>
      </div>` : '';
  }
  return `
    <div class="bloc-profil">
      <h3 class="titre">${moi ? 'Ma vitrine' : t('Sa vitrine')}</h3>
      <div class="mur-vitrine">${v.map((x) => `
        <button class="piece-vitrine" onclick="ferme('joueur');ouvreVisionneuse(${x.id})"
                title="${echappe(x.titre || x.nom)}">
          <img src="${image(photoDePiece(x))}" alt="" loading="lazy">
          ${x.qualite ? `<span class="gemme q${x.qualite}"></span>` : ''}
          <span class="nom">${echappe(x.titre || x.nom)}</span>
        </button>`).join('')}</div>
      ${moi ? `<button class="secondaire" onclick="ouvreChoixVitrine()">${t('Modifier')}</button>` : ''}
    </div>`;
}

/* Les succès d'un joueur.
 *
 * On dit qu'un succès est débloqué — c'est une fierté, elle se montre — mais on
 * ne montre la grenouille que si on l'a soi-même décrochée. Le serveur ne
 * l'envoie même pas dans le cas contraire : `montrable` porte la décision, et
 * la silhouette noire tient lieu de réponse. */
function succesDuProfil(j) {
  const s = j.succes || [];
  if (!s.length) return '';
  const caches = s.filter((x) => !x.montrable).length;
  return `
    <div class="bloc-profil">
      <h3 class="titre">${t('Ses succès')} <span class="doux">${s.length}</span></h3>
      <div class="mur-succes-profil">${s.map((x) => `
        <button class="succes-profil ${x.montrable ? '' : 'voile'}"
                ${x.montrable ? `style="--teinte-succes:${
                  echappe((x.couleurs || COULEURS_DEFAUT).corps)}"` : ''}
                ${x.montrable ? `onclick="ferme('joueur');ouvreSucces('${x.cle}')"`
                              : 'disabled'}
                title="${echappe(x.nom)}${x.obtenu_le
                  ? ` — ${x.obtenu_le.split(' ')[0]}` : ''}">
          ${x.montrable
            ? Media.modele(0, { noir: false, auto: false, classe: 'remplit',
                                modele: x.modele })
            : '<span class="silhouette-inconnue">?</span>'}
          <span class="nom">${x.emoji} ${echappe(x.nom)}</span>
        </button>`).join('')}</div>
      ${caches ? `<p class="doux" style="font-size:11.5px">
        ${t('{0} en silhouette : on ne dévoile pas une récompense que tu n\'as pas encore gagnée.', [caches === 1 ? 'Un succès reste' : `${t('{0} succès restent', [caches])}`])}</p>` : ''}
    </div>`;
}

/* Composer sa vitrine : on coche, l'ordre suit celui des clics. */
async function ouvreChoixVitrine() {
  try {
    const d = await appel('/moi/vitrine/choix');
    etat.choixVitrine = { ...d, choisies: [...d.choisies] };
    etat.joueur = null;
    dessine();
  } catch (e) { signale(e.message, true); }
}

function vueChoixVitrine() {
  const c = etat.choixVitrine;
  if (!c) return '';
  return `
    <div class="voile-modale" onclick="if(event.target===this)ferme('choixVitrine')">
      <div class="modale">
        <div class="dedans">
          <h2>${t('Ma vitrine')}</h2>
          <p class="doux" style="font-size:12.5px">
            ${t('{0} sur {1}. L\'ordre est celui dans lequel tu les choisis.', [c.choisies.length, c.max])}</p>
          ${c.photos.length ? `
            <div class="mur serre">${c.photos.map((p) => {
              const i = c.choisies.indexOf(p.id);
              return `
                <div class="tuile ${i >= 0 ? 'choisie' : ''}"
                     onclick="basculeChoixVitrine(${p.id})"
                     title="${echappe(p.titre || p.nom)}">
                  <img src="${image(photoDePiece(p))}" alt="" loading="lazy">
                  ${i >= 0 ? `<span class="coche">${i + 1}</span>` : ''}
                </div>`;
            }).join('')}</div>`
            : messageVide(t('Rien à montrer'), t('Identifie une photo pour commencer.'))}
        </div>
        <div class="pied">
          <button class="discret" onclick="ferme('choixVitrine')">${t('Annuler')}</button>
          <button class="principal" onclick="enregistreVitrine()">${t('Enregistrer')}</button>
        </div>
      </div>
    </div>`;
}

/* Cocher une photo dans le choix de la vitrine.
 *
 * Nommée `basculeVitrine` à l'origine — comme la bascule du bandeau, deux
 * cents lignes plus haut. Deux fonctions du même nom dans le même fichier : la
 * seconde écrasait la première, si bien que le 🎖 du bandeau appelait celle-ci,
 * qui sortait aussitôt sur `if (!c) return;`. Aucune erreur, aucun effet.
 */
function basculeChoixVitrine(id) {
  const c = etat.choixVitrine;
  if (!c) return;
  const i = c.choisies.indexOf(id);
  if (i >= 0) c.choisies.splice(i, 1);
  else if (c.choisies.length >= c.max) {
    signale(`${t('Six photos au maximum. Décoche-en une d\'abord.')}`, true);
    return;
  } else c.choisies.push(id);
  dessine();
}

async function enregistreVitrine() {
  const c = etat.choixVitrine;
  if (!c) return;
  try {
    await appel('/moi/vitrine', { method: 'PUT', body: { captures: c.choisies } });
    etat.choixVitrine = null;
    signale(t('Vitrine enregistrée.'));
    if (etat.moi) ouvreJoueur(etat.moi.id);
    else dessine();
  } catch (e) { signale(e.message, true); }
}

/* Ce qu'un joueur a trouvé, chargé au fur et à mesure.
 *
 * Douze lignes partaient d'office avec le profil : on les payait à chaque
 * ouverture même sans les regarder, et il n'y avait aucun moyen d'en voir la
 * treizième. Elles arrivent maintenant par pages, à la demande — c'est le
 * défilement de la fiche qui les appelle. */
function trouvaillesDuProfil(j) {
  const tr = etat.trouvaillesJoueur;
  if (!j.nb_trouvailles) return '';
  return `
    <div class="bloc-profil">
      <h3 class="titre">${t('Ses trouvailles')} <span class="doux">${j.nb_trouvailles}</span></h3>
      ${tr?.liste.length ? `
        <div class="liste-trouvailles">${tr.liste.map((d) => `
          <button class="ligne" onclick="ferme('joueur');ouvreFiche(${d.case_id})">
            ${d.visuel ? `<img class="silhouette" src="${image(d.visuel)}" alt="">`
                       : '<span class="rond"></span>'}
            <span class="texte"><b>${echappe(d.nom_fr || d.latin)}</b>
              <span class="doux">${quand(d.trouve_le)}</span></span>
            <span class="gemme q${d.rarete}"></span>
          </button>`).join('')}</div>` : ''}
      ${tr?.charge ? Media.chargement(30) : ''}
      ${!tr || (!tr.fin && !tr.charge) ? `
        <button class="secondaire" onclick="chargeTrouvaillesJoueur()">
          ${tr ? 'En voir plus' : t('Voir ses trouvailles')}</button>` : ''}
    </div>`;
}

async function chargeTrouvaillesJoueur() {
  const j = etat.joueur;
  if (!j) return;
  const tr = etat.trouvaillesJoueur;
  if (tr?.charge || tr?.fin) return;
  const depuis = tr?.liste.length || 0;
  etat.trouvaillesJoueur = { liste: tr?.liste || [], fin: false, charge: true };
  dessine();
  try {
    const d = await appel(
      `/utilisateurs/${j.id}/trouvailles?limite=20&depuis=${depuis}`);
    // Le profil a pu changer pendant la requête : on ne verse pas les
    // trouvailles de quelqu'un dans la fiche d'un autre.
    if (etat.joueur?.id !== j.id) return;
    etat.trouvaillesJoueur = {
      liste: [...(tr?.liste || []), ...(d.trouvailles || [])],
      fin: !!d.fin, charge: false,
    };
  } catch (e) {
    etat.trouvaillesJoueur = { liste: tr?.liste || [], fin: true, charge: false };
    signale(e.message, true);
  }
  dessine();
}

function vueJoueur() {
  const j = etat.joueur;
  if (!j) return '';
  return `
    <div class="feuille" onclick="if(event.target===this)ferme('joueur')">
      <div class="corps" style="text-align:center">
        <div class="poignee"></div>
        <!-- Une croix, parce que le fond ne suffit pas.
             Cette feuille ne se fermait qu'en touchant le voile autour ; avec
             la vitrine, les succès et les trouvailles empilés dedans, elle
             remplit l'écran et il ne reste plus de voile à toucher. On
             ouvrait le profil d'un ami et on y restait. -->
        <button class="outil ferme-feuille" onclick="ferme('joueur')"
                aria-label="${t('Fermer')}">✕</button>
        ${j.avatar
          ? `<img class="avatar grand" src="${image(j.avatar)}" alt="">`
          : `<span class="avatar grand vide-av">${echappe((j.pseudo || '?')[0].toUpperCase())}</span>`}
        <h2 style="margin:10px 0 2px">${echappe(j.pseudo)}</h2>
        <p class="doux" style="margin:0">${t('{0} espèce(s)', [j.cases ?? 0])}</p>
        ${j.bio ? `<p style="font-size:13.5px">${echappe(j.bio)}</p>` : ''}
        <div style="margin:14px 0;display:flex;gap:8px;justify-content:center;flex-wrap:wrap">
          ${bouton(j)}
          ${j.relation !== 'moi' ? `<button class="secondaire"
            onclick="ouvreDexJoueur(${j.id}, '${echappe(j.pseudo)}')">${t('Voir son dex')}</button>` : ''}
        </div>
        <div style="text-align:left">
          ${detailDesPoints(etat.detailJoueur)}
          ${bellesPrises(etat.detailJoueur?.meilleures, t('Ses plus belles prises'))}
        </div>
        ${vitrineDuProfil(j)}
        ${succesDuProfil(j)}
        ${trouvaillesDuProfil(j)}
      </div>
    </div>`;
}

/* ───────────────────── classement, paliers, notifications ───────────────── */

function ongletDuClassement(k) {
  etat.ongletClassement = k;
  dessine();
  if (k === 'trouvailles' && !etat.trouvailles) chargeTrouvailles();
}

async function chargeTrouvailles() {
  try {
    const r = await appel('/classement/trouvailles?limite=60');
    etat.trouvailles = r.trouvailles || [];
  } catch (e) { etat.trouvailles = []; signale(e.message, true); }
  dessine();
}

async function chargeClassement() {
  try {
    const [r, moi] = await Promise.all([
      appel('/classement'),
      appel('/classement/moi').catch(() => null),
    ]);
    etat.classement = r.joueurs || [];
    etat.classementMoi = moi;
  } catch (e) { etat.erreur = e.message; }
  dessine();
}

async function chargePaliers() {
  try { etat.paliers = await appel('/paliers'); } catch (e) { etat.erreur = e.message; }
  dessine();
}

async function chargeNotifications() {
  try {
    const r = await appel('/notifications');
    etat.notifications = r.notifications || [];
    etat.nonLues = 0;
    await appel('/notifications/lues', { method: 'POST' }).catch(() => {});
  } catch (e) { etat.erreur = e.message; }
  dessine();
}

async function chargeMesCaptures() {
  const p = new URLSearchParams({ limite: 120 });
  // « Toutes » n'est pas un état : on ne l'envoie pas, sinon le serveur
  // chercherait des captures dont la colonne `etat` vaudrait « tout ».
  if (etat.filtrePhotos && etat.filtrePhotos !== 'tout') {
    p.set('etat', etat.filtrePhotos);
  }
  try {
    const r = await appel(`/captures?${p}`);
    etat.mesCaptures = r.captures || [];
  } catch (e) { etat.erreur = e.message; }
  dessine();
}

async function chargeCredits() {
  try { etat.credits = await appel('/credits'); } catch (e) { etat.erreur = e.message; }
  dessine();
}

/* ────────────────────────────────── carte ────────────────────────────────── */

async function chargeCarte() {
  try {
    const r = await appel('/carte');
    etat.carte = r.points || [];
  } catch (e) { etat.erreur = e.message; }
  dessine();
}

/* Leaflet est chargé à la demande : la carte est un écran qu'on ouvre
 * rarement, et son script pèse plus que tout le reste de la page. */
let leafletPret = false;
function chargeLeaflet() {
  if (leafletPret) return Promise.resolve();
  return new Promise((ok) => {
    const css = document.createElement('link');
    css.rel = 'stylesheet';
    css.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
    document.head.appendChild(css);
    const js = document.createElement('script');
    js.src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
    js.onload = () => { leafletPret = true; ok(); };
    document.head.appendChild(js);
  });
}

/* Les fonds de carte, les mêmes que sur l'application.
 *
 * Aucun ne demande de clé : ni compte à créer, ni facture. Le satellite est le
 * défaut parce que c'est celui qui donne envie de fouiller — on reconnaît la
 * mare, la haie, le coin de champ. Le plan reste plus lisible en ville, et le
 * relief sert quand on cherche à se situer en montagne. */
const FONDS = {
  satellite: {
    nom: 'Satellite',
    url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/'
       + 'MapServer/tile/{z}/{y}/{x}',
    credit: 'Esri, Maxar, Earthstar Geographics',
    zoomMax: 19,
  },
  plan: {
    nom: t('Plan'),
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    credit: t('© OpenStreetMap'),
    zoomMax: 19,
  },
  relief: {
    nom: t('Relief'),
    url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    credit: t('© OpenTopoMap, OpenStreetMap'),
    zoomMax: 17,
  },
};

/* Le fond choisi survit à la fermeture : quelqu'un qui préfère le plan ne veut
 * pas le redemander à chaque ouverture. */
function fondCourant() {
  const choisi = localStorage.getItem('biodex_fond_carte');
  return FONDS[choisi] ? choisi : 'satellite';
}

function poseFond(m, cle = fondCourant()) {
  const f = FONDS[cle] || FONDS.satellite;
  return L.tileLayer(f.url, { maxZoom: f.zoomMax, attribution: f.credit }).addTo(m);
}

function changeFond(cle) {
  localStorage.setItem('biodex_fond_carte', cle);
  dessine();
}

function puceFonds(actif = fondCourant()) {
  return `<div class="puces">${Object.entries(FONDS).map(([k, f]) => `
    <button class="puce ${k === actif ? 'actif' : ''}" style="--c:var(--accent)"
            onclick="changeFond('${k}')">${f.nom}</button>`).join('')}</div>`;
}

let carte;
async function dessineCarte() {
  await chargeLeaflet();
  const cible = document.getElementById('carte');
  if (!cible || !window.L) return;
  carte = L.map(cible, { zoomControl: false }).setView([46.6, 2.3], 5);
  L.control.zoom({ position: 'topright' }).addTo(carte);
  poseFond(carte);

  const couche = L.layerGroup().addTo(carte);
  const points = pointsCarteFiltres().filter((p) => p.lat != null && p.lon != null);
  poseLesVignettes(carte, couche, points);
  // Le regroupement dépend du zoom : on le refait à chaque fois qu'on bouge.
  // Et on retient le cadrage : la page se redessine souvent — une photo
  // ouverte, un filtre — et la carte doit se retrouver là où on l'a laissée.
  carte.on('moveend zoomend', () => {
    poseLesVignettes(carte, couche, points);
    const c = carte.getCenter();
    etat.carteVue = { centre: [c.lat, c.lng], zoom: carte.getZoom() };
  });

  if (etat.carteVue) {
    carte.setView(etat.carteVue.centre, etat.carteVue.zoom, { animate: false });
  } else if (points.length) {
    carte.fitBounds(points.map((p) => [p.lat, p.lon]), { padding: [30, 30], maxZoom: 16 });
  }
}

/* Les photos d'un même lieu, en planche.
 *
 * Le nom du lieu vient de la première qui en porte un : les photos d'un paquet
 * sont au même endroit, elles ont donc le même lieu, mais toutes ne l'ont pas
 * forcément renseigné. */
function ouvreLeLieu(groupe) {
  const nomme = groupe.find((p) => p.lieu);
  etat.lieu = {
    titre: nomme?.lieu || `${groupe.length} photos ici`,
    photos: groupe,
  };
  dessine();
}

function vuePhotosDuLieu() {
  const l = etat.lieu;
  if (!l) return '';
  // Ce qu'on n'a pas vu passe devant : c'est pour ça qu'on a ouvert le paquet.
  const photos = [...l.photos].sort((a, b) => (a.vue - b.vue));
  const neuves = photos.filter((p) => !p.vue && !p.moi).length;
  // La suite de la visionneuse : tout le paquet, pour balayer d'une photo à
  // l'autre sans repasser par la carte.
  const suite = photos.map((p) => p.capture_id).filter(Boolean);
  return `
    <div class="feuille" onclick="if(event.target===this)ferme('lieu')">
      <div class="corps">
        <div class="poignee"></div>
        <button class="outil ferme-feuille" onclick="ferme('lieu')"
                aria-label="${t('Fermer')}">✕</button>
        <h3 class="titre" style="margin-left:0">📍 ${echappe(l.titre)}</h3>
        <p class="doux" style="font-size:12.5px;margin-top:-4px">
          ${t('{0} photo{1} à cet endroit{2}.', [photos.length, photos.length > 1 ? 's' : '', 
            neuves ? ` · <b style="color:var(--alerte)">${t('{0} pas encore vue{1}', [neuves, neuves > 1 ? 's' : ''])}</b>` : ''])}</p>
        <div class="mur">${photos.map((p) => `
          <div class="tuile ${p.vue ? '' : 'neuve'}"
               onclick="voirSurCarte(${p.capture_id}, ${JSON.stringify(suite)})">
            <img src="${image(p.vignette)}${p.vignette.includes('?') ? '&' : '?'}taille=256"
                 alt="" loading="lazy">
            ${avatar(p, 20, false)}
            <div class="voile"><span>${echappe(p.nom || 'Photo')}</span></div>
          </div>`).join('')}</div>
      </div>
    </div>`;
}

/* Le dex d'un ami, en planche.
 *
 * L'application le montre depuis le profil ; le site n'avait que ses
 * trouvailles en liste. La grille est celle du dex, avec les mêmes tuiles —
 * on touche une case, on tombe sur la fiche de l'espèce. */
async function ouvreDexJoueur(id, pseudo) {
  etat.dexJoueur = { id, pseudo, cases: null };
  dessine();
  try {
    // Rouvert depuis l'historique, on n'a que l'identifiant : le pseudo se
    // demande au serveur, sinon la planche s'intitulerait « Dex de ».
    if (!pseudo) {
      const j = await appel(`/utilisateurs/${id}`);
      if (etat.dexJoueur?.id === id) etat.dexJoueur.pseudo = j.pseudo || '';
    }
    const d = await appel(`/dex?${new URLSearchParams({
      joueur: id, etat: 'decouvert', limite: 120, tri: 'recentes' })}`);
    if (etat.dexJoueur?.id === id) etat.dexJoueur.cases = d.cases || [];
  } catch (e) { signale(e.message, true); etat.dexJoueur = null; }
  dessine();
}

function vueDexJoueur() {
  const d = etat.dexJoueur;
  if (!d) return '';
  return `
    <div class="feuille" onclick="if(event.target===this)ferme('dexJoueur')">
      <div class="corps">
        <div class="poignee"></div>
        <button class="outil ferme-feuille" onclick="ferme('dexJoueur')"
                aria-label="${t('Fermer')}">✕</button>
        <h3 class="titre" style="margin-left:0">${t('Dex de {0}', [echappe(d.pseudo)])}</h3>
        ${d.cases === null ? Media.chargement()
          : d.cases.length
            ? `<div class="grille-dex">${d.cases.map(caseHTML).join('')}</div>`
            : `<div class="vide">${t('Rien trouvé pour l\'instant.')}</div>`}
      </div>
    </div>`;
}

/* Tout effacer, comme dans l'application. Les réactions elles-mêmes ne sont
 * pas touchées : seule la liste des avis disparaît. */
async function videNotifications() {
  if (!confirm(t('Tout effacer ?\\n\\nLes réactions elles-mêmes ne sont pas touchées.'))) return;
  try {
    await appel('/notifications', { method: 'DELETE' });
    etat.notifications = [];
    etat.nonLues = 0;
    dessine();
  } catch (e) { signale(e.message, true); }
}

/* Relâcher la bête : la photo est supprimée et l'espèce quitte le dex.
 *
 * Ce n'est pas un geste décoratif : la capture disparaît, et si c'était la
 * seule de la case, l'espèce redevient à trouver et ses points sont perdus.
 * D'où la confirmation, qui dit exactement ce qu'on abandonne — et
 * l'animation de l'application, portée dans `relache.js`. */
async function demandeRelache(c) {
  const nom = c.case?.nom_fr || c.verdict || 'cette espèce';
  if (!confirm(`${t('Relâcher cette prise ?\\n\\nLa photo sera supprimée. Si c\'était ta')} `
             + `${t('seule photo de « {0} », l\'espèce quittera ton dex et ses points', [nom])} `
             + `${t('avec.\\n\\nC\'est définitif.')}`)) return;
  try {
    await appel(`/captures/${c.id}`, { method: 'DELETE' });
  } catch (e) { signale(e.message, true); return; }
  // Le verdict s'efface avant l'animation : il ne reste que la photo, et la
  // bête qui s'en va. Garder la carte donnerait l'impression que la case est
  // encore acquise.
  const img = document.querySelector('.analyse img.grande');
  for (const el of document.querySelectorAll('.analyse > :not(img.grande)')) el.remove();
  Relache.joue(img, {
    couleur: getComputedStyle(document.documentElement).getPropertyValue('--accent').trim(),
    surFin: () => {
      signale(t('Relâchée. Bonne route.'));
      chargeResume();
      Object.assign(etat, { trouvees: [], aTrouver: [],
                            galerie: [], galerieDepuis: 0, galerieFin: false });
      nouvellePhoto();
    },
  });
}

/* Regrouper les photos par paquet de pixels à l'écran.
 *
 * Deux photos prises au même endroit se superposaient exactement : on n'en
 * voyait qu'une, et rien ne disait qu'il y en avait d'autres dessous. Plutôt
 * qu'un plugin de regroupement à charger depuis le réseau, on découpe l'écran
 * en cases de la taille d'une vignette : tout ce qui tombe dans la même case
 * forme un paquet. Le regroupement suit donc le zoom tout seul — on s'éloigne,
 * les cases couvrent plus de terrain, les paquets grossissent.
 *
 * Le calcul se fait en pixels du conteneur et non en degrés : à latitude
 * élevée, un degré de longitude vaut beaucoup moins de pixels qu'à
 * l'équateur, et des paquets en degrés seraient étirés vers les pôles.
 */
function groupesDeCarte(carte, points, taille = TAILLES_BULLES[tailleBulles()] + 14) {
  const cases = new Map();
  for (const p of points) {
    const pt = carte.latLngToContainerPoint([p.lat, p.lon]);
    const cle = `${Math.floor(pt.x / taille)}:${Math.floor(pt.y / taille)}`;
    if (!cases.has(cle)) cases.set(cle, []);
    cases.get(cle).push(p);
  }
  return [...cases.values()];
}

/* Les vignettes elles-mêmes.
 *
 * `divIcon` et non `L.marker` par défaut : on veut la photo, pas une punaise.
 * La découpe passe avant la vignette quand elle existe — un animal détouré se
 * lit bien mieux à cette taille qu'un cadre où il occupe un dixième de
 * l'image. */
function poseLesVignettes(carte, couche, points) {
  couche.clearLayers();
  for (const groupe of groupesDeCarte(carte, points)) {
    // La tête du paquet : une photo pas encore vue si possible — c'est elle
    // qu'on a envie de montrer — sinon la plus récente.
    const tete = groupe.find((p) => !p.vue && !p.moi) || groupe[0];
    const reste = groupe.length - 1;
    const neuves = groupe.filter((p) => !p.vue && !p.moi).length;
    // La vignette, jamais la découpe : toutes au même format, elles remplissent
    // le rond de la même façon ; les découpes, aux proportions irrégulières,
    // se retrouvaient décapitées une fois sur deux.
    const px = TAILLES_BULLES[tailleBulles()];
    const img = `${image(tete.vignette)}${tete.vignette.includes('?') ? '&' : '?'}taille=${px > 48 ? 256 : 160}`;
    // La tête de l'auteur sur la bulle : à qui est la photo, d'un coup d'œil.
    const tetes = [...new Map(groupe.map((p) => [p.utilisateur, p])).values()].slice(0, 2);
    const icone = L.divIcon({
      className: 'pin-vide',
      iconSize: [px, px],
      iconAnchor: [px / 2, px / 2],
      // La photo en fond, et non dans une balise `<img>` : Leaflet impose
      // `width: auto` aux images de son calque de marqueurs, et chaque bulle
      // devenait une ellipse à la mesure du fichier.
      html: `<span class="pin-photo${reste ? ' pile' : ''}${neuves ? ' neuf' : ''}"
                   style="background-image:url('${img}');width:${px}px;height:${px}px">
               ${reste ? `<i class="nb">+${reste}</i>` : ''}
               <span class="auteurs">${tetes.map((p) => avatar(p, Math.max(14, Math.round(px * .38)), false)).join('')}</span>
             </span>`,
    });
    const m = L.marker([tete.lat, tete.lon], { icon: icone }).addTo(couche);

    // Un paquet s'ouvre en planche : vingt photos prises au même endroit ont
    // les mêmes coordonnées, aucun zoom ne les sépare.
    if (reste) {
      m.on('click', () => ouvreLeLieu(groupe));
      m.bindTooltip(`${t('{0} photos{1}', [groupe.length, neuves ? ` ${t('· {0} nouvelle{1}', [neuves, neuves > 1 ? 's' : ''])}` : ''])}`);
      continue;
    }
    // Une seule photo : elle s'ouvre directement. Le popup intermédiaire
    // « Voir la photo » était un appui de plus pour rien.
    m.on('click', () => voirSurCarte(tete.capture_id));
    m.bindTooltip(`${tete.nom || 'Photo'} — ${tete.pseudo}`);
  }
}

/* ────────────────────────────────── profil ────────────────────────────────── */

async function envoieAvatar(entree) {
  const f = entree.files?.[0];
  if (!f) return;
  const forme = new FormData();
  forme.append('photo', f);
  try {
    await appel('/moi/avatar', { method: 'POST', body: forme });
    await chargeMoi();
    signale(t('Avatar mis à jour.'));
  } catch (e) { signale(e.message, true); }
}

function changeCasesEntieres(valeur) {
  etat.casesEntieres = valeur;
  localStorage.setItem(CASES_ENTIERES, valeur ? '1' : '0');
  dessine();
}

/* La clé ne revient jamais en clair du serveur : il n'en renvoie que les
 * quatre derniers caractères. On ne peut donc pas préremplir le champ, et
 * l'envoyer vide effacerait la clé — d'où le bouton « Retirer » distinct, qui
 * dit ce qu'il fait. */
async function changeClePlantnet(valeur = null) {
  const champ = document.getElementById('cle_plantnet');
  const cle = valeur !== null ? valeur : (champ?.value || '').trim();
  if (valeur === null && !cle) { signale(t('Saisis une clé.'), true); return; }
  if (valeur === '' && !confirm(t('Retirer la clé Pl@ntNet ?'))) return;
  try {
    etat.moi = await appel('/moi/plantnet', { method: 'PUT', body: { cle } });
    signale(cle ? 'Clé enregistrée.' : t('Clé retirée.'));
    dessine();
  } catch (e) { signale(e.message, true); }
}

async function changeBio() {
  const bio = document.getElementById('bio').value;
  try {
    etat.moi = await appel('/moi', { method: 'PATCH', body: { bio } });
    signale(t('Bio enregistrée.'));
  } catch (e) { signale(e.message, true); }
}

async function changeMdp() {
  const ancien = document.getElementById('mdp_ancien').value;
  const neuf = document.getElementById('mdp_neuf').value;
  try {
    await appel('/moi/mot-de-passe',
                { method: 'POST', body: { ancien, nouveau: neuf } });
    signale(t('Mot de passe changé.'));
  } catch (e) { signale(e.message, true); }
}

/* ═══════════════════════════════ la navigation ════════════════════════════ */

const CHARGEURS = {
  dex: () => { if (!etat.trouvees.length && !etat.aTrouver.length) chargeDex(); chargeResume();
               if (!etat.disposition) Disposition.charge(); },
  capture: chargeEnAttente,
  galerie: () => { if (!etat.galerie.length) chargeGalerie(true); },
  amis: () => { chargeAmis(); if (!etat.fil.length) chargeFil(); },
  classement: chargeClassement,
  paliers: chargePaliers,
  notifications: chargeNotifications,
  mescaptures: chargeMesCaptures,
  carte: chargeCarte,
  credits: chargeCredits,
  reglages: chargeVersionSite,
  profil: chargeMoi,
};

function va(v) {
  // La capture en cours ne survit pas à un changement d'écran.
  //
  // Elle n'était effacée que par « nouvelle photo » : on prenait une photo,
  // on quittait sans l'enregistrer, et elle restait en mémoire. En rouvrant
  // ensuite la capture d'un ami — celle sur laquelle on venait d'être
  // identifié — c'est l'ancienne qui s'affichait. Montrer la photo de
  // quelqu'un d'autre est le pire défaut que puisse avoir cet écran.
  //
  // On la garde seulement en revenant sur « photographier » : l'analyse y est
  // peut-être encore en cours, et l'interrompre perdrait le suivi.
  if (v !== 'capture') etat.captureEnCours = null;
  etat.vue = v;
  etat.fiche = null;
  etat.visionneuse = null;
  etat.joueur = null;
  etat.sortie = null;
  etat.choisies.clear();
  dessine();
  CHARGEURS[v]?.();
}

/* Le défilement infini, pour les deux écrans qui paginent. */
/* Les flèches du clavier dans la visionneuse. Sur un ordinateur, personne ne
 * glisse du doigt, et viser un bouton de trente pixels pour passer cinquante
 * photos est pénible. */
addEventListener('keydown', (e) => {
  if (!etat.visionneuse || etat.situer || etat.editeur) return;
  if (e.key === 'ArrowLeft') glisseVisionneuse(-1);
  else if (e.key === 'ArrowRight') glisseVisionneuse(1);
  else if (e.key === 'Escape') ferme('visionneuse');
});

/* Le défilement infini, pour la galerie — le seul écran qui pagine. */
/* Le défilement dans la fiche d'un joueur charge la suite de ses trouvailles.
 * La fiche défile dans son propre corps, pas dans la page : c'est ce conteneur
 * qu'il faut écouter, et il est recréé à chaque rendu. */
function poseDefilementProfil() {
  const corps = document.querySelector('.feuille .corps');
  if (!corps || !etat.joueur || corps.dataset.suivi) return;
  corps.dataset.suivi = 'oui';
  corps.addEventListener('scroll', () => {
    const tr = etat.trouvaillesJoueur;
    if (!tr || tr.charge || tr.fin) return;
    if (corps.scrollTop + corps.clientHeight > corps.scrollHeight - 300) {
      chargeTrouvaillesJoueur();
    }
  }, { passive: true });
}

addEventListener('scroll', () => {
  if (etat.charge) return;
  if (innerHeight + scrollY < document.body.offsetHeight - 700) return;
  if (etat.vue === 'galerie' && !etat.galerieFin) chargeGalerie();
});




/* ═════════════════════════ la rupture du cristal ═══════════════════════
 *
 * Un succès qui tombe ne s'annonce pas par une ligne de texte. Il arrive
 * enfermé dans une gemme qu'on touche, qui se fissure, dont la lumière
 * s'échappe, et qui s'ouvre sur la grenouille en 3D.
 *
 * Le rendu est dans `cristal.js` ; ici on ne fait qu'orchestrer, et retenir ce
 * qui a déjà été ouvert.
 *
 * **On ne casse la même gemme qu'une fois.** Rouvrir un succès déjà découvert
 * montre le modèle directement : refaire l'animation à chaque visite la
 * transformerait en péage. Le souvenir tient dans le navigateur — le serveur
 * n'a pas à savoir ce qu'on a regardé.
 */
const OUVERTS = 'biodex_succes_ouverts';

function dejaOuverts() {
  try { return new Set(JSON.parse(localStorage.getItem(OUVERTS) || '[]')); }
  catch (_) { return new Set(); }
}

function retientOuvert(cle) {
  const s = dejaOuverts();
  s.add(cle);
  localStorage.setItem(OUVERTS, JSON.stringify([...s]));
}

/* Les couleurs de la gemme viennent du serveur, qui les a tirées des pixels du
 * modèle : le corps de la grenouille pour la matière, sa couleur d'accent — le
 * chapeau, l'écharpe — pour la lumière des fissures. Voir
 * `outils/couleurs_succes.py`.
 *
 * Elles remplacent les trois teintes de difficulté, qui rendaient vingt-neuf
 * gemmes interchangeables et répétaient une information déjà écrite sur la
 * tuile. */
const COULEURS_DEFAUT = { corps: '#7fc7ff', fissure: '#ffd27f' };

/* Le shader veut trois flottants entre zéro et un, pas une chaîne. */
function versRvb(hexa) {
  const n = parseInt((hexa || '').replace('#', ''), 16);
  if (!Number.isFinite(n)) return [0.5, 0.78, 1];
  return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
}

let cristalEnCours = null;

/* Ouvre la gemme d'un succès en plein écran.
 *
 * `essai` sert au bouton de test : il joue toute l'animation sans rien retenir
 * ni rien écrire au serveur. */
async function ouvreCristal(cle, essai = false) {
  const s = etat.succes?.succes.find((x) => x.cle === cle);
  if (!s) return;

  const voile = document.createElement('div');
  voile.className = 'rupture';
  voile.innerHTML = `
    <div class="scene">
      <canvas class="gemme-3d"></canvas>
      <div class="socle"></div>
    </div>
    <p class="invite">${t('Touche le cristal')}</p>
    <button class="fermer-rupture" aria-label="${t('Fermer')}">✕</button>`;
  document.body.appendChild(voile);
  document.body.classList.add('sans-defilement');

  const toile = voile.querySelector('canvas');
  const invite = voile.querySelector('.invite');

  // Trente canevas animés derrière un lancer de rayon, c'est ce qui fait
  // saccader l'animation. On les suspend le temps de l'écran, et on les rend
  // dans tous les cas — d'où le passage unique par `parti()`.
  Media.endors();
  let rendu = false;
  // Déclaré avant `parti`, qui le retire : une `const` posée plus bas serait
  // dans sa zone morte si la fermeture arrivait entre-temps.
  let auClavier = () => {};
  const parti = () => {
    cristalEnCours?.arrete();
    cristalEnCours = null;
    voile.remove();
    document.body.classList.remove('sans-defilement');
    removeEventListener('keydown', auClavier);
    if (!rendu) { rendu = true; Media.reveilleTout(); }
  };
  voile.querySelector('.fermer-rupture').onclick = parti;
  // Le fond et la touche Échap ferment aussi. Un panneau plein écran dont on ne
  // sort que par une croix de trente pixels est un piège.
  voile.addEventListener('click', (e) => { if (e.target === voile) parti(); });
  auClavier = (e) => { if (e.key === 'Escape') parti(); };
  addEventListener('keydown', auClavier);

  let gemme;
  try {
    gemme = await pose3D(toile, s, () => revele(voile, s, essai));
  } catch (e) {
    // WebGL indisponible — un vieux navigateur, une machine sans pilote 3D.
    // On ne prive personne de son succès pour autant : on montre directement
    // ce qu'il y avait dedans.
    console.warn('cristal :', e.message);
    revele(voile, s, essai);
    return;
  }
  cristalEnCours = gemme;

  const casse = () => {
    if (gemme.brisee()) return;
    gemme.brise();
    invite.textContent = '';
    voile.classList.add('brise');
  };
  toile.addEventListener('click', casse);
  toile.addEventListener('touchstart', (e) => { e.preventDefault(); casse(); },
                         { passive: false });
}

function pose3D(toile, s, surFin) {
  const c = s.couleurs || COULEURS_DEFAUT;
  return Cristal.pose(toile, {
    teinte: versRvb(c.corps),
    lueur: versRvb(c.fissure),
    surFin,
  });
}

/* Ce qu'il y avait dans la gemme. Le canevas s'efface, le modèle prend sa
 * place — pas l'inverse : voir la grenouille apparaître derrière des éclats qui
 * s'attardent gâche les deux. */
function revele(voile, s, essai) {
  if (!essai) retientOuvert(s.cle);
  cristalEnCours?.arrete();
  cristalEnCours = null;

  voile.classList.add('revele');
  voile.querySelector('.scene').innerHTML = `
    <model-viewer
      src="media/${s.modele}.glb"
      poster="media/${s.modele}_apercu.webp"
      alt="${echappe(s.nom)}"
      camera-controls auto-rotate
      camera-orbit="0deg 72deg 105%"
      field-of-view="30deg"
      rotation-per-second="26deg"
      shadow-intensity="1" exposure="1.1"
      touch-action="none" disable-pan
    ></model-viewer>`;
  voile.querySelector('.invite').innerHTML = `
    <b>${s.emoji} ${echappe(s.nom)}</b>
    <span>${echappe(s.comment || '')}</span>`;

  // La grille derrière porte encore la silhouette noire du succès : elle doit
  // s'allumer, sinon on referme sur un écran qui n'a pas bougé.
  if (!essai) chargeSucces();
}


/* ═══════════════════════════ l'appui long ═══════════════════════════════
 *
 * Rester appuyé sur une vignette la sélectionne, comme dans l'application.
 *
 * Sur Safari iOS, un appui long sur une image déclenche le menu du système —
 * « Enregistrer l'image », « Copier » — et une prévisualisation qui grossit
 * sous le doigt. Ce n'est pas une fatalité : c'est le comportement par défaut
 * du « callout », et il se désactive. Trois choses sont nécessaires ensemble,
 * et il en manque une suffit à ce que rien ne marche :
 *
 *   1. `-webkit-touch-callout: none` sur la vignette — supprime le menu ;
 *   2. `user-select: none` — supprime la sélection de texte et la loupe ;
 *   3. `draggable="false"` sur l'image — sinon le glissement natif la prend.
 *
 * Les deux premières sont dans la feuille de style, la troisième est posée
 * ici. Le reste est un minuteur : on arme à `touchstart`, on désarme si le
 * doigt bouge de plus de dix pixels (c'est un défilement, pas un appui) ou
 * s'il se lève avant l'échéance.
 *
 * 420 ms : en dessous, un défilement un peu hésitant déclenche la sélection ;
 * au-dessus, on croit que ça n'a pas marché et on relâche.
 */
const DELAI_APPUI_LONG = 420;

/* Quand le dernier appui long a abouti.
 *
 * **Le piège, et il coûte cher.** L'appui long agit tout de suite — cocher une
 * photo redessine la page. L'élément qui portait le `touchstart` n'existe donc
 * plus quand le doigt se lève : son gestionnaire de `touchend` ne s'exécute
 * jamais, le `preventDefault` non plus, et le clic que le navigateur synthétise
 * ensuite atterrit sur l'élément **neuf**, à la même place. En sélection, ce
 * clic rappelle `bascule` : on cochait puis on décochait aussitôt, sans avoir
 * bougé le doigt.
 *
 * Le garde-fou vit donc hors du DOM, sur la fenêtre, et avale le clic qui suit
 * un appui long — quel que soit l'élément qui le reçoit.
 */
let appuiLongA = 0;

addEventListener('click', (e) => {
  if (!appuiLongA || performance.now() - appuiLongA > 700) return;
  appuiLongA = 0;
  e.stopPropagation();
  e.preventDefault();
}, true);   // en capture : avant que le gestionnaire de la tuile ne le voie

function poseAppuiLong() {
  for (const tuile of document.querySelectorAll('[data-appui-long]')) {
    if (tuile.dataset.arme) continue;
    tuile.dataset.arme = 'oui';

    // Safari prend l'image en glissement natif si on ne le lui interdit pas,
    // et le minuteur ne reçoit jamais son échéance.
    for (const img of tuile.querySelectorAll('img')) img.draggable = false;

    const id = Number(tuile.dataset.appuiLong);
    // Deux usages du même geste. Sur une vignette de galerie il coche ; sur une
    // ligne d'espèce il montre la fiche — sans avoir à viser la vignette de
    // quarante pixels, ce qui est le geste naturel quand on hésite entre deux
    // mésanges.
    const role = tuile.dataset.appuiRole || 'selection';
    const agir = () => {
      if (role === 'arrangement') { Disposition.entre(etat.trouvees); return; }
      if (role === 'apercu') {
        let donnees = {};
        try { donnees = JSON.parse(tuile.dataset.appuiDonnees || '{}'); }
        catch (_) { /* sans les détails, la fiche se charge quand même */ }
        ouvreApercu(id, donnees);
      } else bascule(id);
    };
    let minuteur = null;
    let depart = null;
    let declenche = false;

    const desarme = () => { clearTimeout(minuteur); minuteur = null; };

    tuile.addEventListener('touchstart', (e) => {
      declenche = false;
      depart = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      minuteur = setTimeout(() => {
        declenche = true;
        // On note l'instant avant d'agir : `agir()` redessine la page, et
        // l'élément qui tient ce gestionnaire disparaît dans l'opération.
        appuiLongA = performance.now();
        // Un retour physique quand il existe : sans lui, on ne sait pas que la
        // sélection a pris tant qu'on n'a pas relevé le doigt. Absent sur iOS,
        // où l'appel est simplement ignoré.
        navigator.vibrate?.(12);
        agir();
      }, DELAI_APPUI_LONG);
    }, { passive: true });

    tuile.addEventListener('touchmove', (e) => {
      if (!depart) return;
      const d = Math.hypot(e.touches[0].clientX - depart.x,
                           e.touches[0].clientY - depart.y);
      if (d > 10) desarme();
    }, { passive: true });

    tuile.addEventListener('touchend', (e) => {
      desarme();
      if (declenche) { e.preventDefault(); declenche = false; }
    });

    tuile.addEventListener('touchcancel', desarme, { passive: true });
  }
}



/* ═════════════════════ le bouton retour du navigateur ══════════════════
 *
 * Sur un site consulté au téléphone, le geste de retour — le glissement depuis
 * le bord sur iPhone, le bouton système sur Android — est aussi instinctif que
 * de toucher l'écran. Sans historique, il quittait purement et simplement
 * l'application : on ouvrait une fiche d'espèce, on glissait pour la fermer, et
 * on se retrouvait sur la page d'avant dans le navigateur.
 *
 * **On n'instrumente pas les quatorze fonctions d'ouverture.** Elles changent
 * l'état et redessinent ; c'est le rendu qui remarque après coup que la
 * position a changé et l'inscrit dans l'historique. Une seule fonction à
 * maintenir au lieu de quatorze, et une nouvelle couche est prise en compte
 * sans qu'on y pense.
 *
 * **La position** est ce qui décrit ce qu'on regarde : l'écran, et la couche
 * ouverte par-dessus s'il y en a une. Deux positions identiques ne créent pas
 * deux entrées — sinon un simple redessin empilerait l'historique et il
 * faudrait appuyer dix fois sur retour pour sortir d'un écran.
 */
const COUCHES = ['fiche', 'visionneuse', 'joueur', 'succesOuvert', 'situer',
                 'choixVitrine', 'choixEspece', 'editeur', 'apercu', 'sortie',
                 'identification', 'nouvelleEspece', 'filtresOuverts',
                 'dexJoueur', 'lieu'];

function positionCourante() {
  for (const c of COUCHES) {
    const v = etat[c];
    if (v) {
      // La clé distingue deux fiches différentes : passer de l'une à l'autre
      // est un déplacement, pas un simple redessin.
      const cle = typeof v === 'object' ? (v.id ?? v.cle ?? 1) : v;
      return { vue: etat.vue, couche: c, cle: String(cle) };
    }
  }
  return { vue: etat.vue, couche: null, cle: null };
}

const memePosition = (a, b) =>
  a && b && a.vue === b.vue && a.couche === b.couche && a.cle === b.cle;

/* Vrai pendant qu'on applique un retour : les fermetures déclenchées à ce
 * moment ne doivent pas repartir dans l'historique. */
let retourEnCours = false;
let positionPrecedente = null;

/* Où en était le défilement de chaque écran. On y revient en revenant : sans
 * ça, fermer une fiche ouverte au bas d'une liste de mille espèces vous
 * ramène en haut, et il faut tout refaire défiler. */
const DEFILEMENTS = new Map();

function noteLaPosition() {
  const p = positionCourante();
  if (memePosition(p, positionPrecedente)) return;

  if (positionPrecedente && !retourEnCours) {
    const cle = `${positionPrecedente.vue}|${positionPrecedente.couche || ''}`;
    DEFILEMENTS.set(cle, scrollY);
  }
  if (!retourEnCours) {
    // `replaceState` pour la toute première position : il n'y a rien derrière,
    // et pousser créerait une entrée fantôme qu'un retour viderait sans effet.
    const methode = positionPrecedente ? 'pushState' : 'replaceState';
    history[methode](p, '', p.couche ? `#${p.vue}/${p.couche}` : `#${p.vue}`);
  }
  positionPrecedente = p;

  if (!p.couche) {
    const y = DEFILEMENTS.get(`${p.vue}|`);
    // Après la peinture : rétablir le défilement avant que le contenu soit
    // posé n'aurait rien à quoi s'appliquer.
    requestAnimationFrame(() => scrollTo(0, retourEnCours && y != null ? y : 0));
  }
}

addEventListener('popstate', (e) => {
  const p = e.state;
  if (!p) return;
  retourEnCours = true;
  try {
    // On referme toutes les couches, puis on rouvre celle que la position
    // demande. Fermer sélectivement supposerait de savoir laquelle a été
    // ouvertes en dernier, ce que l'historique dit déjà.
    for (const c of COUCHES) if (etat[c]) etat[c] = null;
    if (p.vue !== etat.vue) {
      etat.vue = p.vue;
      dessine();
      CHARGEURS[p.vue]?.();
    } else {
      dessine();
    }
    if (p.couche) rouvreLaCouche(p.couche, p.cle);
  } finally {
    // Après le rendu : `noteLaPosition` s'exécute dans `dessine()`, et doit
    // encore voir qu'on est en train de revenir en arrière.
    setTimeout(() => { retourEnCours = false; }, 0);
  }
});

/* Rouvrir une couche depuis l'historique. Toutes ne se rouvrent pas : une
 * modale de saisie à moitié remplie n'a rien à restaurer, et la rouvrir vide
 * serait plus déroutant que de ne pas la rouvrir. */
function rouvreLaCouche(nom, cle) {
  const id = Number(cle);
  if (nom === 'fiche' && id) ouvreFiche(id);
  else if (nom === 'visionneuse' && id) ouvreVisionneuse(id);
  else if (nom === 'joueur' && id) ouvreJoueur(id);
  else if (nom === 'dexJoueur' && id) ouvreDexJoueur(id, etat.joueur?.pseudo || '');
  else if (nom === 'succesOuvert') { etat.succesOuvert = cle; dessine(); }
  else if (nom === 'filtresOuverts') { etat.filtresOuverts = true; dessine(); }
}

/* ═══════════════════════════ les réglages ══════════════════════════════
 *
 * Ils vivaient éparpillés au bas du profil, entre la bio et les statistiques :
 * le cadrage des cases existait depuis des jours sans que personne le trouve.
 * Un écran dédié coûte un appui de plus et les rend consultables — ce qui est
 * l'inverse d'un compromis.
 *
 * **Le thème.** Trois états et non deux. « Système » est le défaut parce que
 * c'est le seul qui n'oblige à rien : quelqu'un qui met son téléphone en sombre
 * le soir ne veut pas le redire ici. Les deux autres existent pour ceux que le
 * choix du système ne satisfait pas.
 *
 * Le thème choisi est posé en attribut sur la racine — `data-theme` — et la
 * feuille de style le lit. Sans choix explicite, aucun attribut n'est posé et
 * `prefers-color-scheme` reprend la main.
 */
const REGLAGES = {
  theme: 'biodex_theme',
  animations: 'biodex_animations',
  confettis: 'biodex_confettis',
  lancer: 'biodex_lancer',
};

function reglage(cle, defaut) {
  const v = localStorage.getItem(REGLAGES[cle]);
  return v === null ? defaut : v === '1';
}

function themeChoisi() {
  const v = localStorage.getItem(REGLAGES.theme);
  return THEMES[v] ? v : 'systeme';
}

/* Les thèmes du site. Les couleurs de l'aperçu sont celles des jetons posés
 * dans `style.css` sous `:root[data-theme=…]` — à tenir à la main, les deux
 * ne se lisent pas l'un l'autre. `sombre` dit si le thème part du mode sombre
 * (barre du navigateur, voile des images). */
const THEMES = {
  systeme: { nom: t('Système'), detail: t('Suit le téléphone'), attr: null,
             apercu: { fond: '#ffffff', fond2: '#f6f7f8', case: '#f1f1f2', texte: '#1b1d21', accent: '#0ea5a4' } },
  clair:   { nom: t('Clair'), detail: t('Blanc, sobre'), attr: 'light',
             apercu: { fond: '#ffffff', fond2: '#f6f7f8', case: '#f1f1f2', texte: '#1b1d21', accent: '#0ea5a4' } },
  sombre:  { nom: t('Sombre'), detail: t('Gris anthracite'), attr: 'dark', sombre: true,
             apercu: { fond: '#121316', fond2: '#1b1d22', case: '#23262c', texte: '#eceef2', accent: '#2fc3c1' } },
  hacker:  { nom: t('Hacker'), detail: t('Pluie de signes'), attr: 'hacker', sombre: true, barre: '#000000', fond: 'matrice',
             apercu: { fond: '#000000', fond2: '#0b140c', case: '#0e1a0f', texte: '#9dffb0', accent: '#22ff5e' } },
  nuit:    { nom: t('Nuit étoilée'), detail: t('Étoiles et filantes'), attr: 'nuit', sombre: true, barre: '#05081a', fond: 'etoiles',
             apercu: { fond: '#070b1e', fond2: '#121a38', case: '#182250', texte: '#e6ebff', accent: '#ffd166' } },
  abysses: { nom: t('Abysses'), detail: t('Bulles et rais de lumière'), attr: 'abysses', sombre: true, barre: '#03101f', fond: 'bulles',
             apercu: { fond: '#06223a', fond2: '#072038', case: '#0a2a47', texte: '#d8f1ff', accent: '#2ee6d6' } },
  neon:    { nom: t('Néon'), detail: t('Grille synthwave'), attr: 'neon', sombre: true, barre: '#0d0620', fond: 'grille',
             apercu: { fond: '#1e0d3a', fond2: '#1b1030', case: '#241540', texte: '#f6e9ff', accent: '#ff3fa4' } },
  foret:   { nom: t('Forêt'), detail: t('Feuilles d\'automne'), attr: 'foret', sombre: true, barre: '#101a14', fond: 'feuilles',
             apercu: { fond: '#14201a', fond2: '#1c2c22', case: '#243a2c', texte: '#e9f3e6', accent: '#d9a441' } },
  sakura:  { nom: t('Sakura'), detail: t('Pétales au vent'), attr: 'sakura', barre: '#e8538a', fond: 'sakura',
             apercu: { fond: '#fff4f8', fond2: '#ffeef3', case: '#fde4ec', texte: '#3a2530', accent: '#e8538a' } },
  hiver:   { nom: t('Hiver'), detail: t('Neige'), attr: 'hiver', barre: '#2f7fd6', fond: 'neige',
             apercu: { fond: '#eef3f9', fond2: '#e8eff7', case: '#dde7f2', texte: '#182636', accent: '#2f7fd6' } },
  aurore:  { nom: t('Aurore boréale'), detail: t('Voiles verts et violets'), attr: 'aurore', sombre: true, barre: '#050b16', fond: 'aurore',
             apercu: { fond: '#07101f', fond2: '#0f1b30', case: '#152640', texte: '#e4f4ff', accent: '#5df2a6' } },
  lucioles: { nom: t('Nuit d\'été'), detail: t('Lucioles'), attr: 'lucioles', sombre: true, barre: '#06130f', fond: 'lucioles',
             apercu: { fond: '#0a1a16', fond2: '#11261f', case: '#17332a', texte: '#eefaf2', accent: '#ffe37a' } },
  savane:  { nom: t('Savane'), detail: t('Soleil couchant, oiseaux'), attr: 'savane', sombre: true, barre: '#2a1612', fond: 'savane',
             apercu: { fond: '#3a1c14', fond2: '#3a211b', case: '#4a2b22', texte: '#ffe9d6', accent: '#ff8c42' } },
  aquarelle: { nom: t('Aquarelle'), detail: t('Taches de couleur'), attr: 'aquarelle', barre: '#4f8fcf', fond: 'aquarelle',
             apercu: { fond: '#fffdf8', fond2: '#f7f3ea', case: '#efe8dc', texte: '#2e2a26', accent: '#4f8fcf' } },
  lagon:   { nom: t('Lagon'), detail: t('Reflets d\'eau'), attr: 'lagon', barre: '#0ab3a6', fond: 'lagon',
             apercu: { fond: '#dff6f6', fond2: '#e3f6f6', case: '#d4f0f0', texte: '#0f3a3d', accent: '#0ab3a6' } },
  nebuleuse: { nom: t('Nébuleuse'), detail: t('Poussière d\'étoiles'), attr: 'nebuleuse', sombre: true, barre: '#0d0a1f', fond: 'nebuleuse',
             apercu: { fond: '#15102c', fond2: '#17122f', case: '#211a40', texte: '#efe9ff', accent: '#c77dff' } },
  carnet:  { nom: t('Carnet'), detail: t('Papier et encre sépia'), attr: 'carnet', barre: '#8a5a2b',
             apercu: { fond: '#f6f0e1', fond2: '#efe6d2', case: '#e9dfc8', texte: '#2d2418', accent: '#8a5a2b' } },
  gameboy: { nom: t('Game Boy'), detail: t('Quatre verts, pixels'), attr: 'gameboy', barre: '#0f380f',
             apercu: { fond: '#cadc9f', fond2: '#bdd08f', case: '#a9bf7d', texte: '#0f380f', accent: '#306230' } },
};

function appliqueTheme() {
  const t = themeChoisi();
  const th = THEMES[t];
  if (!th.attr) document.documentElement.removeAttribute('data-theme');
  else document.documentElement.dataset.theme = th.attr;
  // Le thème hacker, c'est un jeu de couleurs et une pluie de signes derrière
  // la page. Elle part et s'arrête avec lui : rien ne tourne pour un autre.
  if (th.fond) Fond.demarre(th.fond); else Fond.arrete();
  // La barre du navigateur suit : sur iOS elle occupe le haut de l'écran, et
  // une bande blanche au-dessus d'une page sombre se voit tout de suite.
  const sombre = !!th.sombre
    || (t === 'systeme' && matchMedia('(prefers-color-scheme: dark)').matches);
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) m.remove();
  const meta = document.createElement('meta');
  meta.name = 'theme-color';
  meta.content = th.barre || (sombre ? '#121316' : '#0ea5a4');
  document.head.appendChild(meta);
}

function changeTheme(v) {
  localStorage.setItem(REGLAGES.theme, v);
  appliqueTheme();
  dessine();
}

function changeReglage(cle, valeur) {
  localStorage.setItem(REGLAGES[cle], valeur ? '1' : '0');
  // Les animations se coupent par une classe sur la racine plutôt qu'en
  // retirant chaque règle : une seule bascule, et rien à tenir à jour quand on
  // ajoute une animation.
  document.documentElement.classList.toggle('sans-animation', !reglage('animations', true));
  const fond = THEMES[themeChoisi()].fond;
  if (fond) { Fond.arrete(); Fond.demarre(fond); }
  dessine();
}

function vueReglages() {
  const choisi = themeChoisi();
  // Une carte par thème, avec un aperçu en vraies couleurs : en-tête, deux
  // cases, une ligne de texte, un point d'accent. On choisit ce qu'on voit.
  const carteTheme = (cle, th) => `
    <button class="carte-theme ${choisi === cle ? 'actif' : ''}" onclick="changeTheme('${cle}')"
            style="--ap-fond:${th.apercu.fond};--ap-fond2:${th.apercu.fond2};--ap-case:${th.apercu.case};--ap-texte:${th.apercu.texte};--ap-accent:${th.apercu.accent}"
            aria-pressed="${choisi === cle}">
      <span class="apercu ${cle === 'systeme' ? 'moitie' : ''}" aria-hidden="true">
        <i class="entete"></i>
        <i class="case"></i><i class="case"></i><i class="case"></i>
        <i class="ligne"></i><i class="point"></i>
      </span>
      <b>${th.nom}${choisi === cle ? ' <span class="coche">✓</span>' : ''}</b>
      <span class="doux">${th.detail}</span>
    </button>`;
  const bascule = (cle, defaut, titre, detail) => `
    <label class="ligne-reglage">
      <span class="texte"><b>${titre}</b>
        <span class="doux">${detail}</span></span>
      <input type="checkbox" ${reglage(cle, defaut) ? 'checked' : ''}
             onchange="changeReglage('${cle}', this.checked)">
    </label>`;

  return `
    <div class="centre">
      <h3 class="titre" style="margin-left:0">${t('Langue')}</h3>
      <div class="puces" style="padding:0">
        <button class="puce ${langueChoisie() === 'auto' ? 'actif' : ''}" style="--c:var(--accent)"
                onclick="changeLangue('auto')">${t('Automatique')}</button>
        ${Object.entries(LANGUES).map(([k, n]) => `
          <button class="puce ${langueChoisie() === k ? 'actif' : ''}" style="--c:var(--accent)"
                  onclick="changeLangue('${k}')">${n}</button>`).join('')}
      </div>

      <h3 class="titre" style="margin-left:0">${t('Affichage')}</h3>
      <p class="doux" style="font-size:12.5px;margin-top:0">${t('Thème')}</p>
      <div class="choix-themes">
        ${Object.entries(THEMES).map(([k, th]) => carteTheme(k, th)).join('')}
      </div>

      <label class="ligne-reglage" style="margin-top:12px">
        <span class="texte"><b>${t('Cases en photo entière')}</b>
          <span class="doux">${t('Plutôt que l\'animal détouré. Les cases réglées à la main gardent leur choix.')}</span></span>
        <input type="checkbox" ${etat.casesEntieres ? 'checked' : ''}
               onchange="changeCasesEntieres(this.checked)">
      </label>

      <p class="doux" style="font-size:12.5px;margin:14px 0 4px">${t('Bulles sur la carte')}</p>
      ${puceTailleBulles()}

      <h3 class="titre" style="margin-left:0">${t('Animations')}</h3>
      ${bascule('animations', true, t('Animations de l\'interface'),
                t('Les apparitions d\'écrans et de vignettes'))}
      ${bascule('lancer', true, t('Lancer de sphère'),
                t('Pendant l\'analyse de la photo'))}
      ${bascule('confettis', true, t('Confettis'),
                t('À chaque nouvelle espèce'))}

      <h3 class="titre" style="margin-left:0">${t('Notifications')}</h3>
      <button class="secondaire" onclick="va('reglagesnotifs')">
        ${t('Ce dont je veux être prévenu')}</button>

      <h3 class="titre" style="margin-left:0">${t('Identification des plantes')}</h3>
      <p class="doux" style="font-size:12.5px;margin-top:0">
        ${t('Pl@ntNet identifie les plantes bien mieux que le modèle général. La clé est personnelle parce que le quota l\'est aussi : cinq cents identifications par jour — une clé partagée serait épuisée en une après-midi. Sans clé, les plantes passent par le modèle général.')}
        <a href="https://my.plantnet.org/" target="_blank" rel="noopener">${t('Obtenir une clé')}</a>.</p>
      <div class="champ">
        <label>${t('Clé Pl@ntNet {0}', [etat.moi?.plantnet?.active
          ? `<span class="doux">${t('— enregistrée ({0})', [echappe(etat.moi.plantnet.apercu)])}</span>`
          : ''])}</label>
        <input id="cle_plantnet" type="password" autocomplete="off"
               placeholder="${etat.moi?.plantnet?.active ? 'Remplacer la clé' : '2b10…'}">
      </div>
      <div class="ligne-actions">
        <button class="secondaire" onclick="changeClePlantnet()">${t('Enregistrer')}</button>
        ${etat.moi?.plantnet?.active ? `
          <button class="secondaire danger" onclick="changeClePlantnet('')">
            ${t('Retirer')}</button>` : ''}
      </div>

      <h3 class="titre" style="margin-left:0">${t('Mon compte')}</h3>
      <div class="champ">
        <label for="bio">${t('Ma bio')}</label>
        <input id="bio" value="${echappe(etat.moi?.bio || '')}" maxlength="200"
               placeholder="${t('Deux mots sur toi')}">
      </div>
      <button class="secondaire" onclick="changeBio()">${t('Enregistrer ma bio')}</button>

      <div class="champ" style="margin-top:16px">
        <label for="mdp_ancien">${t('Mot de passe actuel')}</label>
        <input id="mdp_ancien" type="password" autocomplete="current-password">
      </div>
      <div class="champ">
        <label for="mdp_neuf">${t('Nouveau mot de passe')}</label>
        <input id="mdp_neuf" type="password" autocomplete="new-password">
      </div>
      <button class="secondaire" onclick="changeMdp()">${t('Changer de mot de passe')}</button>

      <button class="secondaire danger" onclick="deconnecte()"
              style="margin-top:24px;width:100%">${t('Se déconnecter')}</button>

      <!-- La version du fichier réellement chargé.
           Sans elle, impossible de distinguer « le correctif ne marche pas »
           de « le téléphone sert encore une vieille copie » — et un site ajouté
           à l'écran d'accueil garde la sienne avec une ténacité remarquable.
           On lit la date du script lui-même : elle ne peut pas mentir. -->
      <p class="doux" style="font-size:11.5px;margin-top:20px">
        ${t('Serveur : {0}', [echappe(location.origin)])}<br>
        ${t('Version du site : {0}', [etat.versionSite === null ? '…'
          : echappe(etat.versionSite || 'inconnue')])}
        <button class="lien" style="font-size:11.5px"
                onclick="rechargeVraiment()">${t('Forcer le rechargement')}</button></p>
    </div>`;
}

/* La date du script chargé par ce navigateur.
 *
 * `cache: 'no-store'` sur la requête, sinon on lirait l'en-tête de la copie en
 * cache et le contrôle ne vaudrait rien. */
async function chargeVersionSite() {
  try {
    const r = await fetch('app.js', { method: 'HEAD', cache: 'no-store' });
    const d = r.headers.get('Last-Modified');
    etat.versionSite = d
      ? new Date(d).toLocaleString('fr-FR',
          { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
      : '';
  } catch (_) { etat.versionSite = ''; }
  dessine();
}

/* Recharger en contournant le cache.
 *
 * Le paramètre change l'URL, donc le navigateur ne peut pas resservir sa
 * copie : c'est le seul moyen fiable depuis un site ajouté à l'écran
 * d'accueil, où le bouton « recharger » n'existe pas. */
function rechargeVraiment() {
  location.replace(`${location.pathname}?v=${Date.now()}`);
}

/* ═══════════════════════════════ situer ═════════════════════════════════
 *
 * Poser une photo sur la carte, et corriger sa date.
 *
 * Le site ne savait faire qu'une chose : prendre la position du téléphone à
 * l'instant présent. C'est juste pour la photo qu'on vient de prendre, et faux
 * pour tout le reste — la sortie d'hier, la photo reçue par messagerie, celle
 * dont l'appareil n'avait pas de GPS. L'application, elle, ouvre une carte
 * qu'on touche.
 *
 * Trois façons de désigner un endroit, parce qu'aucune ne suffit seule :
 *   — le doigt sur la carte, quand on reconnaît le lieu ;
 *   — le nom tapé, quand on sait comment ça s'appelle mais pas où c'est ;
 *   — la position courante, quand on est encore sur place.
 *
 * Le nom du lieu se remplit tout seul au clic (géocodage inverse) mais reste
 * modifiable : « Bois de Vincennes » vaut mieux que l'adresse à rallonge que
 * rend Nominatim.
 */

/* On ouvre sur une photo, et `aussi` porte le reste du lot. Le serveur ne sait
 * traiter qu'une capture à la fois : la boucle est ici, en série — douze
 * écritures d'une ligne sur un SQLite ne gagnent rien à partir ensemble. */
/* Poser le lieu de la photo qu'on vient d'analyser.
 *
 * On relit l'objet dans l'état plutôt que de le sérialiser dans le `onclick` :
 * `apostrophes()`, l'aide habituelle pour ça, ne retient que les champs d'une
 * espèce et laisserait tomber `lat`, `lon` et l'heure. */
function situeLaCapture() {
  if (etat.captureEnCours) ouvreSituer(etat.captureEnCours);
}

function ouvreSituer(capture, aussi = []) {
  const quand = capture.prise_le || capture.cree_le || null;
  etat.situer = {
    id: capture.id ?? capture.capture_id,
    aussi,
    lat: capture.lat ?? null,
    lon: capture.lon ?? null,
    lieu: capture.lieu || '',
    // `datetime-local` veut « AAAA-MM-JJTHH:MM » et rien d'autre.
    quand: quand ? String(quand).replace(' ', 'T').slice(0, 16) : '',
    recherche: '', resultats: null, cherche: false,
    travaille: false,
  };
  dessine();
}

/* N'y a-t-il vraiment rien à enregistrer ?
 *
 * Un nom de lieu compte autant qu'un point sur la carte : « au fond du jardin »
 * est une information, même sans coordonnées. Il était exclu, si bien qu'on
 * pouvait remplir le champ et rester bloqué.
 */
function rienASituer(s) {
  return s.lat == null && !s.quand && !(s.lieu || '').trim();
}

/* Réactiver « Enregistrer » à la saisie, sans tout redessiner.
 *
 * Les champs n'écrivaient que dans l'état : l'attribut `disabled` du bouton,
 * calculé au rendu, n'était donc jamais recalculé. On tapait une date, le
 * bouton restait gris, et il n'y avait aucun moyen d'enregistrer sans passer
 * par la carte. Un `dessine()` complet réglerait le compte mais ferait perdre
 * le focus et le curseur à chaque frappe : on ne touche que ce qui change.
 */
function majSituer() {
  const s = etat.situer;
  if (!s) return;
  const b = document.querySelector('.modale-situer .pied .principal');
  if (b) b.disabled = !!s.travaille || rienASituer(s);
  const aide = document.querySelector('.modale-situer .pourquoi-inactif');
  if (aide) {
    aide.textContent = rienASituer(s)
      ? 'Pose un point, une date ou un nom de lieu.' : '';
  }
}

function vueSituer() {
  const s = etat.situer;
  if (!s) return '';
  const n = 1 + s.aussi.length;
  return `
    <div class="voile-modale" onclick="if(event.target===this)ferme('situer')">
      <div class="modale modale-situer">
        <div class="dedans">
          <h2>${n > 1 ? `${t('Situer {0} photos', [n])}` : t('Date et lieu')}</h2>
          ${n > 1 ? `<p class="doux" style="font-size:12.5px">
            ${t('Le même lieu et la même date seront posés sur les {0}.', [n])}</p>` : ''}

          <label class="titre-champ">${t('Chercher un lieu')}</label>
          <div class="ligne-filtres">
            <input class="champ" placeholder="${t('Bois de Vincennes, Annecy…')}"
                   value="${echappe(s.recherche)}"
                   onkeydown="if(event.key==='Enter'){event.preventDefault();chercheLieu(this.value)}">
            <button class="secondaire" onclick="chercheLieu(
              this.parentElement.querySelector('input').value)">${t('Chercher')}</button>
          </div>
          ${s.cherche ? Media.chargement(28) : ''}
          ${s.resultats ? (s.resultats.length ? `
            <div class="resultats-lieux">${s.resultats.map((l, i) => `
              <button class="ligne" onclick="retientLieu(${i})">
                <span class="texte">${echappe(l.nom)}</span></button>`).join('')}
            </div>` : `<p class="doux" style="font-size:12.5px">${t('Aucun lieu trouvé.')}</p>`)
            : ''}

          <div id="carte-situer" class="carte-situer"></div>
          <p class="doux" style="font-size:12px;margin:4px 0 0">
            ${t('Touche la carte pour poser le point.')}</p>

          <label class="titre-champ">${t('Nom du lieu')}</label>
          <input class="champ" data-role="nom-lieu" value="${echappe(s.lieu)}"
                 maxlength="200" placeholder="${t('Optionnel')}"
                 oninput="etat.situer.lieu = this.value; majSituer()">

          <label class="titre-champ">${t('Date et heure')}</label>
          <input class="champ" type="datetime-local" value="${s.quand}"
                 oninput="etat.situer.quand = this.value; majSituer()">

          <button class="secondaire" style="margin-top:10px"
                  onclick="situerIci()">${t('📍 Utiliser ma position')}</button>
          <!-- Le message d'aide vit sous les champs, pas dans la barre du bas.
               Posé dans le pied, il en occupait l'espace libre et poussait
               « Enregistrer » hors du cadre. -->
          <p class="doux pourquoi-inactif"
             style="font-size:11.5px;margin:10px 0 0">${
            rienASituer(s) ? 'Pose un point, une date ou un nom de lieu.' : ''}</p>
        </div>
        <div class="pied">
          <button class="discret" onclick="ferme('situer')">${t('Annuler')}</button>
          <button class="principal" onclick="enregistreSituation()"
                  ${s.travaille || rienASituer(s) ? 'disabled' : ''}>
            ${s.travaille ? 'Enregistrement…' : t('Enregistrer')}</button>
        </div>
      </div>
    </div>`;
}

/* La carte du panneau. Séparée de celle de l'écran « Carte » : elles n'ont ni
 * la même durée de vie ni le même rôle, et partager la variable ferait qu'en
 * fermer une détruirait l'autre. */
let carteSituer;
async function dessineCarteSituer() {
  const s = etat.situer;
  if (!s) { carteSituer = null; return; }
  await chargeLeaflet();
  const cible = document.getElementById('carte-situer');
  if (!cible || !window.L) return;

  // Leaflet marque le nœud qu'il occupe et refuse de l'initialiser deux fois.
  // S'il est déjà marqué, c'est que ce rendu ne l'a pas remplacé : rien à faire.
  if (cible._leaflet_id) return;

  const depart = s.lat != null ? [s.lat, s.lon] : [46.6, 2.3];
  carteSituer = L.map(cible).setView(depart, s.lat != null ? 14 : 5);
  poseFond(carteSituer);

  let marque = s.lat != null ? L.marker(depart).addTo(carteSituer) : null;
  carteSituer.on('click', (e) => {
    const premier = s.lat == null;
    s.lat = e.latlng.lat;
    s.lon = e.latlng.lng;
    if (marque) marque.setLatLng(e.latlng);
    else marque = L.marker(e.latlng).addTo(carteSituer);
    nommeLePoint(s.lat, s.lon);
    // « Enregistrer » passe d'inactif à actif au premier point posé : c'est le
    // seul moment où il faut redessiner. Le faire à chaque clic arracherait la
    // carte sous le doigt.
    if (premier) rafraichitSituer();
  });
}

/* Redessiner le panneau sans perdre la carte de vue. `dessine()` remplace tout
 * le document : la carte est recréée, et il faut la remettre où elle était. */
async function rafraichitSituer() {
  const vue = carteSituer
    ? { centre: carteSituer.getCenter(), zoom: carteSituer.getZoom() } : null;
  carteSituer = null;
  dessine();
  await dessineCarteSituer();
  if (vue) carteSituer?.setView(vue.centre, vue.zoom);
}

/* Le nom de l'endroit, demandé au serveur. Silencieux s'il échoue : un point
 * sans nom reste un point valable, et refuser d'enregistrer pour ça serait
 * absurde. */
async function nommeLePoint(lat, lon) {
  try {
    const d = await appel(`/geocodage/inverse?lat=${lat}&lon=${lon}`);
    if (!etat.situer || !d.nom) return;
    // Nominatim rend des adresses à rallonge ; les deux premiers éléments
    // suffisent à reconnaître l'endroit.
    etat.situer.lieu = d.nom.split(',').slice(0, 2).join(',').trim();
    // On ne touche qu'au champ, pas au reste : refaire la page ici arracherait
    // la carte alors que le doigt est encore dessus.
    const champ = document.querySelector('.modale-situer [data-role="nom-lieu"]');
    if (champ) champ.value = etat.situer.lieu;
  } catch (_) { /* sans importance */ }
}

async function chercheLieu(texte) {
  const s = etat.situer;
  if (!s || !texte || texte.trim().length < 2) return;
  s.recherche = texte;
  s.cherche = true;
  s.resultats = null;
  await rafraichitSituer();
  try {
    const d = await appel(`/geocodage?q=${encodeURIComponent(texte.trim())}`);
    if (etat.situer) etat.situer.resultats = d.lieux || [];
  } catch (e) {
    if (etat.situer) { etat.situer.resultats = []; signale(e.message, true); }
  } finally {
    if (etat.situer) { etat.situer.cherche = false; await rafraichitSituer(); }
  }
}

function retientLieu(i) {
  const s = etat.situer;
  const l = s?.resultats?.[i];
  if (!l) return;
  s.lat = l.lat;
  s.lon = l.lon;
  s.lieu = l.nom.split(',').slice(0, 2).join(',').trim();
  s.resultats = null;
  // La carte doit se recentrer sur le nouveau point : on la laisse repartir de
  // zéro plutôt que de restaurer l'ancienne vue.
  carteSituer = null;
  dessine();
  dessineCarteSituer();
}

async function situerIci() {
  const s = etat.situer;
  if (!s) return;
  try {
    const p = await new Promise((ok, non) => {
      if (!navigator.geolocation) return non(new Error(t('Localisation indisponible.')));
      navigator.geolocation.getCurrentPosition(ok,
        () => non(new Error(t('Position refusée. Autorise la localisation.'))),
        { timeout: 8000, enableHighAccuracy: true });
    });
    s.lat = p.coords.latitude;
    s.lon = p.coords.longitude;
    nommeLePoint(s.lat, s.lon);
    carteSituer = null;
    dessine();
    dessineCarteSituer();
  } catch (e) { signale(e.message, true); }
}

async function enregistreSituation() {
  const s = etat.situer;
  if (!s || s.travaille) return;
  const corps = {};
  if (s.lat != null && s.lon != null) { corps.lat = s.lat; corps.lon = s.lon; }
  if (s.lieu) corps.lieu = s.lieu;
  // Le serveur veut « AAAA-MM-JJ HH:MM:SS » ; le champ du navigateur rend
  // « AAAA-MM-JJTHH:MM », sans les secondes.
  if (s.quand) corps.prise_le = `${s.quand.replace('T', ' ')}:00`;
  if (!Object.keys(corps).length) return;

  s.travaille = true;
  dessine();
  const lot = [s.id, ...s.aussi];
  try {
    let faites = 0;
    for (const id of lot) {
      await appel(`/captures/${id}/lieu`, { method: 'PATCH', body: corps });
      faites += 1;
    }
    etat.situer = null;
    carteSituer = null;
    etat.choisies.clear();
    etat.aSituerChoisies?.clear();
    etat.choisiesPhotos?.clear();
    signale(faites > 1 ? `${t('{0} photos situées.', [faites])}` : t('Photo située.'));
    // Tout ce qui dépend du lieu ou de la date est périmé.
    etat.orphelines = null;
    etat.carte = [];
    if (etat.visionneuse) {
      try { etat.visionneuse = await appel(`/captures/${etat.visionneuse.id}`); }
      catch (_) { /* la photo a pu disparaître entre-temps */ }
    }
    // La photo qu'on vient d'analyser, si c'est d'elle qu'il s'agit. C'est le
    // cas le plus courant — on pose le lieu juste après la prise — et il était
    // le seul oublié : l'écran continuait d'afficher « lieu inconnu » et
    // l'ancienne date, alors que la base était à jour.
    if (etat.captureEnCours && lot.includes(etat.captureEnCours.id)) {
      try { etat.captureEnCours = await appel(`/captures/${etat.captureEnCours.id}`); }
      catch (_) { /* rien de grave : l'écran suivant la relira */ }
    }
    if (etat.mesCaptures.length) chargeMesCaptures();
    chargeGalerie(true);
    if (etat.vue === 'asituer') chargeOrphelines();
    if (etat.vue === 'carte') chargeCarte();
  } catch (e) {
    signale(e.message, true);
    if (etat.situer) { etat.situer.travaille = false; dessine(); }
  }
}

/* ─────────────────────────── le fil temps réel ──────────────────────────
 *
 * Le badge de notifications se mettait à jour au chargement de la page, et
 * nulle part ailleurs : pour voir qu'un ami avait réagi, il fallait recharger.
 *
 * On ne sonde pas pour autant. Le serveur garde une connexion ouverte
 * (`GET /notifications/flux`) et n'écrit dessus qu'au moment où quelque chose
 * arrive — voir `biodex/flux.py`. Tant qu'il ne se passe rien, ça ne coûte
 * ni requête ni réveil.
 *
 * `EventSource` aurait été l'outil prévu pour ça, mais il ne sait pas poser
 * d'en-tête `Authorization` : il aurait fallu mettre le jeton dans l'URL. On
 * lit donc le flux à la main avec `fetch`, ce qui est une vingtaine de lignes
 * de plus et garde le jeton là où il doit être.
 */
let filEnCours = null;      // le contrôleur d'abandon de la connexion ouverte
let filAttente = 1000;      // le délai avant reconnexion, qui double à chaque échec

function ouvreLeFil() {
  if (filEnCours || !etat.moi) return;
  const j = jeton();
  if (!j) return;

  const abandon = new AbortController();
  filEnCours = abandon;

  (async () => {
    try {
      const r = await fetch(`${API}/notifications/flux`, {
        headers: { Authorization: `Bearer ${j}` },
        signal: abandon.signal,
      });
      if (!r.ok || !r.body) throw new Error(`flux ${r.status}`);

      const lecteur = r.body.getReader();
      const decodeur = new TextDecoder();
      let tampon = '';

      for (;;) {
        const { done, value } = await lecteur.read();
        if (done) break;
        tampon += decodeur.decode(value, { stream: true });

        // Un événement SSE se termine par une ligne vide. On ne traite que les
        // blocs complets : une trame TCP peut couper au milieu d'un message.
        let coupe;
        while ((coupe = tampon.indexOf('\n\n')) !== -1) {
          const bloc = tampon.slice(0, coupe);
          tampon = tampon.slice(coupe + 2);
          const type = (bloc.match(/^event: (.+)$/m) || [])[1];
          // `ouvert` confirme la connexion : le délai de reconnexion repart de
          // zéro, sinon une coupure réseau de la veille pénaliserait encore.
          if (type === 'ouvert') { filAttente = 1000; continue; }
          if (type) surEvenementDuFil(type);
        }
      }
    } catch (_) {
      // Coupure, veille de l'appareil, serveur redémarré : rien à dire au
      // joueur. On se rebranche.
    } finally {
      if (filEnCours === abandon) {
        filEnCours = null;
        // Reconnexion à délai croissant, plafonné à une minute. Sans le
        // plafond on abandonnerait ; sans la croissance, un serveur éteint se
        // ferait marteler.
        if (etat.moi && !document.hidden) {
          setTimeout(ouvreLeFil, filAttente);
          filAttente = Math.min(filAttente * 2, 60000);
        }
      }
    }
  })();
}

function fermeLeFil() {
  const c = filEnCours;
  filEnCours = null;
  c?.abort();
}

/* Ce qu'on fait d'un réveil. Le serveur n'envoie que le fait qu'il y a du
 * neuf : c'est ici qu'on va chercher quoi. */
async function surEvenementDuFil(type) {
  if (type !== 'notifications') return;
  try {
    const n = await appel('/notifications');
    const avant = etat.nonLues;
    etat.nonLues = n.non_lues || 0;

    // Si l'écran des notifications est ouvert, la liste se remplace sous les
    // yeux — et comme on les regarde, elles sont lues.
    if (etat.vue === 'notifications') {
      etat.notifications = n.notifications || [];
      etat.nonLues = 0;
      appel('/notifications/lues', { method: 'POST' }).catch(() => {});
      dessine();
      return;
    }
    if (etat.nonLues !== avant) {
      dessine();
      // Un badge qui apparaît sans bouger passe inaperçu sur un téléphone
      // qu'on tient à bout de bras.
      if (etat.nonLues > avant) sursaute('.compteur');
    }
  } catch (_) {}
}

/* Un onglet en arrière-plan n'a pas besoin de connexion ouverte : les
 * navigateurs mobiles la coupent de toute façon en veille, et la garder
 * déclencherait une reconnexion perdue toutes les minutes. */
addEventListener('visibilitychange', () => {
  if (document.hidden) { fermeLeFil(); return; }
  filAttente = 1000;
  ouvreLeFil();
  // Au retour, on rattrape ce qui s'est passé pendant l'absence.
  if (etat.moi) surEvenementDuFil('notifications');
});

async function demarre() {
  await chargeMoi();
  if (!etat.moi) { etat.vue = 'connexion'; dessine(); return; }
  // La disposition du dex part en même temps que le dex lui-même. Elle
  // n'était demandée qu'en *revenant* sur l'onglet : au lancement, le dex
  // s'affichait en grille automatique et l'arrangement semblait perdu.
  await Promise.all([chargeDex(), Disposition.charge()]);
  chargeResume();
  reprendLaVitrine();
  ouvreLeFil();
}

(async function () {
  appliqueTheme();
  document.documentElement.classList.toggle('sans-animation',
                                            !reglage('animations', true));
  const j = jeton();
  // On réaligne les deux dépôts : celui qui a survécu réamorce l'autre.
  if (j) { localStorage.setItem(JETON, j); poseBiscuit(j); await demarre(); return; }
  dessine();
})();
