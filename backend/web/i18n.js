/*
 * La langue du site.
 *
 * Le français est la langue source : chaque texte de l'interface est écrit en
 * français dans le code, et c'est ce texte qui sert de clé. `t('Se connecter')`
 * rend la traduction si le dictionnaire de la langue en cours en a une, et le
 * français sinon — un texte oublié dans une traduction reste lisible, il n'est
 * jamais remplacé par une clé technique.
 *
 * Les dictionnaires vivent dans `lang/<code>.json` (la source, pour qui
 * traduit) et `lang/<code>.js` (la même chose, chargée ici par un `<script>`
 * synchrone). Synchrone, parce que des tables de noms — classes d'animaux,
 * thèmes, réactions — sont traduites au chargement de `app.js` : le
 * dictionnaire doit être là avant.
 *
 * Les textes à trous : `t('{0} photos', [n])`. Les trous sont numérotés et
 * non nommés, parce qu'une traduction peut les réordonner.
 */
const LANGUES = { fr: 'Français', en: 'English' };
const LANGUE_SOURCE = 'fr';

function langueChoisie() {
  let l = 'auto';
  try { l = localStorage.getItem('biodex_langue') || 'auto'; } catch (_) {}
  return l;
}

/* La langue effective : celle choisie, ou celle du navigateur si elle existe
 * chez nous, et le français à défaut. */
function langueCourante() {
  const choisie = langueChoisie();
  if (choisie !== 'auto' && LANGUES[choisie]) return choisie;
  const nav = (navigator.language || LANGUE_SOURCE).slice(0, 2).toLowerCase();
  return LANGUES[nav] ? nav : LANGUE_SOURCE;
}

window.BIODEX_DICO = {};
(() => {
  const l = langueCourante();
  document.documentElement.lang = l;
  if (l === LANGUE_SOURCE) return;
  // `document.write` pendant l'analyse de la page : le script s'exécute avant
  // ceux qui suivent, c'est exactement ce qu'on veut.
  document.write(`<script src="lang/${l}.js"><\/script>`);
})();

function t(cle, args) {
  let s = window.BIODEX_DICO[cle];
  if (s === undefined) s = cle;
  if (args) {
    for (let i = 0; i < args.length; i++) {
      s = s.split(`{${i}}`).join(args[i] == null ? '' : String(args[i]));
    }
  }
  return s;
}

/* Changer de langue recharge la page : trop de tables sont traduites au
 * chargement pour retraduire à la volée, et un rechargement vaut mieux qu'une
 * page à moitié traduite. */
function changeLangue(l) {
  try { localStorage.setItem('biodex_langue', l); } catch (_) {}
  location.reload();
}
