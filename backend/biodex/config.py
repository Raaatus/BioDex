"""
Configuration centrale.

Tout est réglable par variable d'environnement, et rien n'est codé en dur vers
un chemin absolu : le projet doit pouvoir être zippé ici puis dézippé n'importe
où sur le serveur sans qu'on ait à éditer une ligne de Python.

Par défaut, les données vivent dans `backend/donnees/`, à côté du code.
Sur le serveur on peut les déporter :  BIODEX_DONNEES=/data/biodex
"""
import os
import pathlib
import secrets

RACINE = pathlib.Path(__file__).resolve().parent.parent


def _chemin(var: str, defaut: pathlib.Path) -> pathlib.Path:
    v = os.environ.get(var)
    return pathlib.Path(v).expanduser().resolve() if v else defaut


def _entier(var: str, defaut: int) -> int:
    try:
        return int(os.environ[var])
    except (KeyError, ValueError):
        return defaut


def _texte(var: str, defaut: str) -> str:
    return os.environ.get(var, "").strip() or defaut


def _flottant(var: str, defaut: float) -> float:
    try:
        return float(os.environ[var])
    except (KeyError, ValueError):
        return defaut


# ---------------------------------------------------------------- emplacements
DONNEES = _chemin("BIODEX_DONNEES", RACINE / "donnees")
MODELES = _chemin("BIODEX_MODELES", DONNEES / "modeles")
PHOTOS = _chemin("BIODEX_PHOTOS", DONNEES / "photos")
VIGNETTES = _chemin("BIODEX_VIGNETTES", DONNEES / "vignettes")
SILHOUETTES = _chemin("BIODEX_SILHOUETTES", DONNEES / "silhouettes")
# Découpes : l'animal détouré sur fond transparent, tel qu'il apparaît dans la
# case du dex une fois l'espèce trouvée.
DECOUPES = _chemin("BIODEX_DECOUPES", DONNEES / "decoupes")
AVATARS = _chemin("BIODEX_AVATARS", DONNEES / "avatars")

BASE = _chemin("BIODEX_BASE", DONNEES / "biodex.sqlite")

# Poids et catalogue : produits par les scripts de `outils/`, ou repris tels
# quels depuis l'ancien projet biodex (ce sont les mêmes fichiers).
MD_POIDS = _chemin("BIODEX_MD_POIDS", MODELES / "md_v5a.0.1.pt")
# Version 2 : la taxonomie GBIF plus les races domestiques. Un labrador n'est
# pas un taxon et ne le sera jamais, mais le classificateur est un CLIP : son
# catalogue n'a pas à être de la taxonomie.
CATALOGUE = _chemin("BIODEX_CATALOGUE", DONNEES / "catalogue_v2.pt")

# ------------------------------------------------------------------- inférence
MODELE_CLIP = os.environ.get("BIODEX_CLIP", "hf-hub:imageomics/bioclip-2")
FILS_TORCH = _entier("BIODEX_FILS_TORCH", 8)
# Le catalogue reste en float16 en mémoire ; le produit scalaire se fait par
# tranches converties à la volée, sinon 411 626 × 768 en float32 fait 1,2 Go.
TRANCHE = _entier("BIODEX_TRANCHE", 200_000)

SEUIL_DETECTION = _flottant("BIODEX_SEUIL_DETECTION", 0.20)
MARGE_CROP = _flottant("BIODEX_MARGE_CROP", 0.08)

# Cascade case -> genre -> rejet. Seuils calés sur le jeu de test de biodex :
# au niveau espèce le modèle hésite entre proches parents (vache/bison à 3× d'écart),
# alors qu'au niveau genre il est catégorique.
SEUIL_ESPECE = _flottant("BIODEX_SEUIL_ESPECE", 0.60)
RATIO_ESPECE = _flottant("BIODEX_RATIO_ESPECE", 5.0)
SEUIL_GENRE = _flottant("BIODEX_SEUIL_GENRE", 0.45)

# Seuils au niveau case. Une case regroupe toutes les sous-espèces et synonymes
# d'une même espèce, donc l'hésitation classique du modèle entre proches parents
# (vache / zébu, qui sont la même case) s'annule ici : on peut être plus exigeant
# sur la masse tout en validant plus souvent qu'au niveau espèce seul.
SEUIL_CASE = _flottant("BIODEX_SEUIL_CASE", 0.55)
RATIO_CASE = _flottant("BIODEX_RATIO_CASE", 4.0)

# Quelles pistes proposer quand le moteur n'a pas tranché. Un nombre fixe de
# propositions est arbitraire : sur une image nette il n'y a qu'un candidat
# sérieux, sur une image douteuse il y en a huit. On garde donc tout ce qui
# dépasse le seuil, avec un plancher pour ne jamais laisser l'écran vide et un
# plafond pour ne pas dérouler une liste illisible.
# ---------------------------------------------------------------- flore et champignons

# Un catalogue par règne : mélanger plantes et champignons dans un même espace
# de labels ne fait qu'ajouter des concurrents et dilue la masse par case.
CATALOGUE_PLANTES = _chemin("BIODEX_CATALOGUE_PLANTES", DONNEES / "catalogue_plantes.pt")
CATALOGUE_CHAMPIGNONS = _chemin("BIODEX_CATALOGUE_CHAMPIGNONS", DONNEES / "catalogue_champi.pt")

# ------------------------------------------------------------------- aquatique
#
# Les poissons ne sont pas un règne : ce sont des animaux, et ils ont déjà leurs
# cases au dex — le poisson-clown est la case 16397. « Aquatique » est une
# lentille, pas un dex parallèle. Le catalogue n'est que le catalogue animal
# réduit à ses 22 766 entrées de poissons, ce qui écarte d'un coup les 356 000
# insectes et oiseaux qui pouvaient gagner sur un reflet.
CATALOGUE_AQUATIQUE = _chemin("BIODEX_CATALOGUE_AQUATIQUE",
                              DONNEES / "catalogue_aquatique.pt")

# Poids de la tête « genre » apprise sur FishNet, ajoutée aux logits d'espèce.
# Zéro la désactive sans toucher au catalogue : c'est le réglage à baisser si
# elle se met à tirer dans le mauvais sens sur des photos d'aquarium, dont elle
# n'a presque pas d'exemples.
POIDS_TETE_GENRES = _flottant("BIODEX_POIDS_TETE_GENRES", 1.0)

# Modèle spécialisé champignons : 2829 espèces, bien plus précis que BioCLIP sur
# son périmètre (0.978 contre 0.578 sur l'amanite tue-mouches). Hors de cette
# liste, en revanche, il se trompe avec assurance — d'où la bascule.
FUNGI_MODELE = _texte("BIODEX_FUNGI_MODELE",
                      "hf-hub:BVRA/tf_efficientnet_b3.in1k_ft_fungitastic_384")
FUNGI_CLASSES = _chemin("BIODEX_FUNGI_CLASSES", DONNEES / "ft_classes.json")
FUNGI_TOXIQUES = _chemin("BIODEX_FUNGI_TOXIQUES", DONNEES / "ft_toxiques.json")

# Seuil de bascule FungiTastic -> BioCLIP champignons.
# CALIBRAGE FRAGILE : mesuré sur 2 champignons connus (0.978 / 0.994) et 6
# images hors périmètre (0.095 à 0.875 — une pâquerette classée en rouille à
# 0.875). La marge n'est que de 0.10 : à réviser dès qu'une vraie série de
# photos sera disponible.
SEUIL_FUNGI = _flottant("BIODEX_SEUIL_FUNGI", 0.70)

# Seuil de bascule Pl@ntNet -> BioCLIP plantes. NON CALIBRÉ faute de mesures sur
# des cas connus et inconnus. La bascule reste automatique en cas d'erreur ou
# d'absence de clé.
SEUIL_PLANTNET = _flottant("BIODEX_SEUIL_PLANTNET", 0.50)
PLANTNET_URL = _texte("BIODEX_PLANTNET_URL",
                      "https://my-api.plantnet.org/v2/identify/all")

# Sans recadrage, les scores sont plus étalés que sur les animaux : MegaDetector
# n'a pas d'équivalent pour la flore, on classe l'image entière.
SEUIL_CASE_FLORE = _flottant("BIODEX_SEUIL_CASE_FLORE", 0.45)
RATIO_CASE_FLORE = _flottant("BIODEX_RATIO_CASE_FLORE", 3.0)

SEUIL_PISTE = _flottant("BIODEX_SEUIL_PISTE", 0.05)
MIN_PISTES = _entier("BIODEX_MIN_PISTES", 3)
MAX_PISTES = _entier("BIODEX_MAX_PISTES", 12)

# A priori d'observation. Le classificateur ne sait pas ce qui est fréquent :
# il met le chevreuil (2,3 millions d'observations) au coude à coude avec le
# huemul du Chili (404 observations, en danger critique). On corrige par la
# règle de Bayes — P(espèce | image) ∝ P(image | espèce) × P(espèce) — en
# estimant P(espèce) par son nombre d'observations GBIF.
#   0    : aucun a priori, on ne juge que sur l'image
#   1    : a priori complet, log P(espèce) ajouté tel quel
# Mesuré avec outils/calibre.py sur le jeu d'images de référence : 3 bonnes
# réponses sur 10 à 0, 8 à 0,5, 10 à 1,0. On garde donc l'a priori complet, qui
# est aussi le choix théoriquement juste.
#
# Contrepartie assumée : une espèce vraiment rare devient difficile à faire
# reconnaître, puisqu'on parie contre elle a priori. C'est le bon compromis pour
# quelqu'un qui photographie ce qu'il croise en se promenant ; baisser cette
# valeur si l'usage devient celui d'un naturaliste en quête de raretés.
PRIOR_OBS = _flottant("BIODEX_PRIOR_OBS", 1.0)

# Mettre à 1 pour démarrer l'API sans charger les modèles : les captures
# s'empilent en file au lieu d'être analysées. Sert à développer l'app sans
# attendre 645 Mo de catalogue à chaque redémarrage.
SANS_MOTEUR = os.environ.get("BIODEX_SANS_MOTEUR", "") == "1"

# --------------------------------------------------------------------- serveur
HOTE = os.environ.get("BIODEX_HOTE", "0.0.0.0")
PORT = _entier("BIODEX_PORT", 8077)

TAILLE_MAX_PHOTO = _entier("BIODEX_TAILLE_MAX_PHOTO", 20 * 1024 * 1024)
COTE_MAX_PHOTO = _entier("BIODEX_COTE_MAX_PHOTO", 2048)   # redimension avant stockage
COTE_VIGNETTE = _entier("BIODEX_COTE_VIGNETTE", 512)
COTE_DECOUPE = _entier("BIODEX_COTE_DECOUPE", 512)
COTE_AVATAR = _entier("BIODEX_COTE_AVATAR", 256)

# Détourage de l'animal. On recadre d'abord sur la boîte de MegaDetector, puis
# on retire le fond : sans le recadrage préalable, le modèle garde volontiers la
# branche sur laquelle l'oiseau est perché.
# Mettre à 0 pour s'en passer (la vignette carrée sert alors de repli).
DETOURAGE = os.environ.get("BIODEX_DETOURAGE", "1") != "0"
MODELE_DETOURAGE = os.environ.get("BIODEX_MODELE_DETOURAGE", "u2net")

# Une photo dont le moteur n'a rien tiré, et que le joueur n'a pas rattachée à
# une espèce, finit par être effacée : elle n'apparaît nulle part et ne fait
# qu'occuper de la place. Le délai laisse le temps de la corriger à la main.
# Mettre 0 pour ne jamais purger.
JOURS_AVANT_PURGE = _entier("BIODEX_JOURS_AVANT_PURGE", 7)

# Durée de vie d'une session. Longue par défaut : sur mobile, on ne veut pas
# retaper son mot de passe toutes les semaines.
DUREE_SESSION_JOURS = _entier("BIODEX_DUREE_SESSION_JOURS", 365)

# Sel serveur pour le hachage des jetons de session. Généré au premier
# démarrage et rangé dans les données ; s'il change, toutes les sessions sautent.
_FICHIER_SEL = DONNEES / "sel_serveur.txt"


def sel_serveur() -> bytes:
    if _FICHIER_SEL.exists():
        return bytes.fromhex(_FICHIER_SEL.read_text().strip())
    DONNEES.mkdir(parents=True, exist_ok=True)
    sel = secrets.token_bytes(32)
    _FICHIER_SEL.write_text(sel.hex())
    _FICHIER_SEL.chmod(0o600)
    return sel


def prepare_dossiers() -> None:
    for d in (DONNEES, MODELES, PHOTOS, VIGNETTES, SILHOUETTES, DECOUPES, AVATARS):
        d.mkdir(parents=True, exist_ok=True)
