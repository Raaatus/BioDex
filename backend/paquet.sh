#!/usr/bin/env bash
#
# Fabrique l'archive à emporter sur le serveur.
#
#     ./paquet.sh                  code + silhouettes + listes de noms
#     ./paquet.sh --avec-modeles   idem, plus le catalogue et MegaDetector
#     ./paquet.sh --code-seul      le code et rien d'autre, pour mettre à jour
#                                  un serveur déjà installé
#
# Ce qui n'y est jamais :
#   - le .venv, à recréer sur place : les roues Python ne sont pas portables ;
#   - les photos des joueurs et tout ce qui en dérive ;
#   - le sel du serveur, propre à chaque installation ;
#   - les sauvegardes de base laissées par remise_a_zero.py ;
#   - catalogue_vivant.pt, l'ancien catalogue remplacé par catalogue_v2.pt.
#
# Sur le serveur :
#     unzip biodex-backend.zip && cd backend
#     python3 -m venv .venv
#     .venv/bin/pip install -r requirements-moteur.txt
#     ./run.sh

set -euo pipefail
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ICI/.."

AVEC_MODELES=0
CODE_SEUL=0
for arg in "$@"; do
    case "$arg" in
        --avec-modeles) AVEC_MODELES=1 ;;
        --code-seul)    CODE_SEUL=1 ;;
        *) echo "Option inconnue : $arg" >&2; exit 1 ;;
    esac
done

ARCHIVE="$ICI/biodex-backend.zip"
rm -f "$ARCHIVE"

EXCLUS=(
    'backend/.venv/*'
    # La base de développement n'a rien à faire sur un serveur : elle porte des
    # comptes d'essai et, surtout, elle écraserait celle des joueurs. Une
    # installation neuve construit la sienne avec outils/construit_dex.py ;
    # une mise à jour garde celle qui est déjà en place.
    'backend/donnees/biodex.sqlite'
    'backend/donnees/biodex.sqlite-wal'
    'backend/donnees/biodex.sqlite-shm'
    'backend/donnees/avant-base-neuve-*.sqlite'
    # Tout ce qui appartient aux joueurs : le serveur repart vierge.
    'backend/donnees/photos/*'
    'backend/donnees/vignettes/*'
    'backend/donnees/decoupes/*'
    'backend/donnees/avatars/*'
    'backend/donnees/miniatures/*'
    # Le sel sert à hacher les jetons de session : en le rejouant d'une machine
    # à l'autre, les jetons d'ici resteraient valables là-bas. Il est régénéré
    # au premier démarrage.
    'backend/donnees/sel_serveur.txt'
    'backend/donnees/avant-remise-a-zero-*.sqlite'
    'backend/donnees/catalogue_vivant.pt'
    'backend/**/__pycache__/*'
    'backend/.pytest_cache/*'
    'backend/biodex-backend.zip'
)
if [ "$AVEC_MODELES" -eq 0 ]; then
    EXCLUS+=('backend/donnees/modeles/*' 'backend/donnees/*.pt')
fi
# La tête genres fait exception, et c'est délibéré : 1,7 Mo, mais elle est
# irremplaçable. La reconstruire demande les 5 Go d'images de FishNet et une
# carte graphique. Le catalogue aquatique, lui, se rebâtit sur place en une
# minute à partir du catalogue animal — inutile de l'envoyer.
INCLUS_MALGRE_TOUT=('backend/donnees/tete_genres.pt')
# Mise à jour d'un serveur qui tourne : on n'envoie que le code. Tout ce qui
# vit dans donnees/ — silhouettes, badges, catalogues, listes de noms — y est
# déjà, et le renvoyer ne ferait que grossir l'archive et allonger la fenêtre
# pendant laquelle le service est arrêté.
if [ "$CODE_SEUL" -eq 1 ]; then
    EXCLUS+=('backend/donnees/*')
    ARCHIVE="$ICI/biodex-code.zip"
    rm -f "$ARCHIVE"
fi

ARGS=()
for e in "${EXCLUS[@]}"; do ARGS+=(-x "$e"); done

zip -r -q "$ARCHIVE" backend "${ARGS[@]}"
for f in "${INCLUS_MALGRE_TOUT[@]}"; do
    [ -f "$f" ] && zip -q "$ARCHIVE" "$f"
done

echo "Archive : $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"
if [ "$CODE_SEUL" -eq 1 ]; then
    echo
    echo "Code seul : ni base, ni photos, ni modèles, ni silhouettes."
    echo "À déployer sur un serveur qui a déjà tout cela."
    echo
    echo "Le règne aquatique a besoin de son catalogue, à bâtir sur place :"
    echo "  .venv/bin/python -m outils.catalogue_poissons \\"
    echo "      --tete donnees/tete_genres.pt"
    exit 0
fi
if [ "$AVEC_MODELES" -eq 0 ]; then
    echo
    echo "Sans les modèles, l'API tourne mais les captures restent en attente."
    # Les quatre, pas deux. Ce message n'en annonçait que deux, et l'oubli ne
    # se voyait pas : avec le seul catalogue animal, les photos d'animaux
    # passent et le serveur a l'air sain. C'est la première plante envoyée qui
    # tombe, en FileNotFoundError, longtemps après l'installation.
    echo "Pour analyser, il faut aussi ces quatre fichiers dans donnees/ :"
    echo "  donnees/catalogue_v2.pt         (624 Mo)  animaux"
    echo "  donnees/catalogue_plantes.pt    (672 Mo)  plantes"
    echo "  donnees/catalogue_champi.pt     (261 Mo)  champignons"
    echo "  donnees/modeles/md_v5a.0.1.pt   (268 Mo)  détecteur"
    echo "Soit en les copiant à la main, soit avec ./paquet.sh --avec-modeles."
fi
