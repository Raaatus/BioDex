#!/usr/bin/env bash
#
# Démarre le serveur.
#
#     ./run.sh                 en production, sur toutes les interfaces
#     ./run.sh --dev           rechargement automatique au moindre changement
#     ./run.sh --sans-moteur   API seule, sans charger les modèles
#
# Les réglages passent par l'environnement, cf. biodex/config.py. Exemple :
#     BIODEX_DONNEES=/data/biodex ./run.sh

set -euo pipefail
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ICI"

PYTHON="${PYTHON:-$ICI/.venv/bin/python}"
if [ ! -x "$PYTHON" ]; then
    echo "Environnement Python introuvable ($PYTHON)." >&2
    echo "Créez-le :  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
    exit 1
fi

HOTE="${BIODEX_HOTE:-0.0.0.0}"
PORT="${BIODEX_PORT:-8077}"
SUPP=()

for arg in "$@"; do
    case "$arg" in
        --dev)          SUPP+=(--reload) ;;
        --sans-moteur)  export BIODEX_SANS_MOTEUR=1 ;;
        *)              echo "Option inconnue : $arg" >&2; exit 1 ;;
    esac
done

echo "Biodex sur http://$HOTE:$PORT"
exec "$PYTHON" -m uvicorn biodex.main:app --host "$HOTE" --port "$PORT" "${SUPP[@]}"
