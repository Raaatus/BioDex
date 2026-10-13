#!/usr/bin/env bash
#
# Compile l'APK avec la chaîne confinée dans .toolchain/.
#
#     ./build.sh              APK de release (à installer sur le téléphone)
#     ./build.sh debug        APK de debug, plus rapide à produire
#     ./build.sh install      compile puis installe sur l'appareil branché
#
# L'APK produit est recopié dans ../apk/biodex.apk — un nom distinct de
# celui de l'ancien projet, qu'on réinstallait par mégarde.

set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$ICI/env.sh" ]; then
    echo "env.sh manquant : lancez d'abord ./installe_toolchain.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ICI/env.sh"

MODE="${1:-release}"

case "$MODE" in
    debug)
        flutter build apk --debug
        SORTIE="build/app/outputs/flutter-apk/app-debug.apk"
        ;;
    install)
        flutter build apk --release
        SORTIE="build/app/outputs/flutter-apk/app-release.apk"
        flutter install --release
        ;;
    release)
        # --split-per-abi produirait trois APK plus légers, mais un APK unique
        # s'envoie plus simplement sur un téléphone au bout du fil.
        flutter build apk --release
        SORTIE="build/app/outputs/flutter-apk/app-release.apk"
        ;;
    *)
        echo "Mode inconnu : $MODE (attendu : release, debug ou install)" >&2
        exit 1
        ;;
esac

mkdir -p "$ICI/../apk"
cp "$ICI/$SORTIE" "$ICI/../apk/biodex.apk"
echo
echo "APK prêt : $(cd "$ICI/../apk" && pwd)/biodex.apk  ($(du -h "$ICI/../apk/biodex.apk" | cut -f1))"
