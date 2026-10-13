#!/usr/bin/env bash
#
# Installe de quoi compiler l'application, sans rien poser sur le système.
#
# Tout atterrit dans ./.toolchain/ : le SDK Flutter, un JDK, et le SDK Android.
# Aucun paquet n'est installé, aucun fichier n'est écrit ailleurs — sauf les
# caches que Gradle et Flutter placent normalement dans ~/.gradle et ~/.pub-cache,
# qu'on redirige ici aussi. Pour tout supprimer :
#
#     rm -rf .toolchain
#
# Le script est idempotent : relancé, il reprend ce qui manque.

set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTILS="$ICI/.toolchain"
mkdir -p "$OUTILS"

# Version figée des outils en ligne de commande Android : ce numéro est celui
# publié par Google, il n'existe pas d'URL « latest » stable.
CMDLINE_TOOLS="commandlinetools-linux-11076708_latest.zip"
# Flutter 3.47 réclame l'API 36 ; garder ces deux valeurs alignées sur ce que
# réclame `flutter doctor`, sinon la compilation refuse de démarrer.
NIVEAU_ANDROID="36"
BUILD_TOOLS="36.0.0"

info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    %s\033[0m\n' "$*"; }

telecharge() {  # url destination
    if [ -f "$2" ]; then ok "déjà téléchargé : $(basename "$2")"; return; fi
    ok "téléchargement de $(basename "$2")"
    curl -fL --progress-bar -o "$2.partiel" "$1"
    mv "$2.partiel" "$2"
}

CACHE="$OUTILS/cache"
mkdir -p "$CACHE"

# ---------------------------------------------------------------- JDK 17
if [ ! -d "$OUTILS/jdk" ]; then
    info "JDK 17 (Temurin)"
    telecharge "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" \
               "$CACHE/jdk17.tar.gz"
    mkdir -p "$OUTILS/jdk"
    tar -xzf "$CACHE/jdk17.tar.gz" -C "$OUTILS/jdk" --strip-components=1
    ok "installé dans .toolchain/jdk"
else
    info "JDK 17 déjà présent"
fi
export JAVA_HOME="$OUTILS/jdk"
export PATH="$JAVA_HOME/bin:$PATH"

# ------------------------------------------------------------- SDK Flutter
if [ ! -d "$OUTILS/flutter" ]; then
    info "SDK Flutter (canal stable)"
    # L'URL de la dernière version stable se lit dans l'index publié par Google,
    # plutôt que d'être écrite en dur et de pourrir à la prochaine sortie.
    INDEX="$CACHE/flutter_releases.json"
    telecharge "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" "$INDEX"
    LECTURE=$(python3 - "$INDEX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hash_stable = d["current_release"]["stable"]
for r in d["releases"]:
    if r["hash"] == hash_stable and r["channel"] == "stable":
        print(d["base_url"] + "/" + r["archive"])
        print(r["version"])
        break
PY
)
    URL=$(echo "$LECTURE" | head -1)
    VERSION=$(echo "$LECTURE" | tail -1)
    ok "version stable : $VERSION"
    telecharge "$URL" "$CACHE/flutter.tar.xz"
    tar -xJf "$CACHE/flutter.tar.xz" -C "$OUTILS"
    ok "installé dans .toolchain/flutter"
else
    info "SDK Flutter déjà présent"
fi

export PUB_CACHE="$OUTILS/pub-cache"
export PATH="$OUTILS/flutter/bin:$PATH"

# ------------------------------------------------------------- SDK Android
export ANDROID_HOME="$OUTILS/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
    info "Outils Android en ligne de commande"
    telecharge "https://dl.google.com/android/repository/$CMDLINE_TOOLS" "$CACHE/cmdline-tools.zip"
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    rm -rf "$ANDROID_HOME/cmdline-tools/tmp"
    unzip -q "$CACHE/cmdline-tools.zip" -d "$ANDROID_HOME/cmdline-tools/tmp"
    mv "$ANDROID_HOME/cmdline-tools/tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rmdir "$ANDROID_HOME/cmdline-tools/tmp"
    ok "installés dans .toolchain/android-sdk"
else
    info "Outils Android déjà présents"
fi

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

info "Composants Android (plateforme $NIVEAU_ANDROID, build-tools $BUILD_TOOLS)"
yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses > /dev/null 2>&1 || true
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
    "platform-tools" \
    "platforms;android-$NIVEAU_ANDROID" \
    "build-tools;$BUILD_TOOLS" > /dev/null
ok "composants installés"

# ------------------------------------------------------- réglages Flutter
info "Configuration de Flutter"
# Ces réglages sont écrits dans .toolchain/flutter/, pas dans le profil de
# l'utilisateur : rien ne survit à la suppression du dossier.
export FLUTTER_ROOT="$OUTILS/flutter"
flutter config --android-sdk "$ANDROID_HOME" > /dev/null
flutter config --no-analytics > /dev/null 2>&1 || true
flutter config --enable-android > /dev/null 2>&1 || true
yes | flutter doctor --android-licenses > /dev/null 2>&1 || true

info "Vérification"
flutter doctor -v 2>&1 | grep -E "^\[|Flutter version|Android SDK|Java version" || true

cat > "$ICI/env.sh" <<EOF
# Généré par installe_toolchain.sh — à sourcer pour utiliser la chaîne confinée :
#     source env.sh
ICI="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export JAVA_HOME="\$ICI/.toolchain/jdk"
export FLUTTER_ROOT="\$ICI/.toolchain/flutter"
export ANDROID_HOME="\$ICI/.toolchain/android-sdk"
export ANDROID_SDK_ROOT="\$ANDROID_HOME"
export PUB_CACHE="\$ICI/.toolchain/pub-cache"
# Gradle range ses caches ici plutôt que dans ~/.gradle, pour que la
# suppression de .toolchain ne laisse vraiment rien derrière.
export GRADLE_USER_HOME="\$ICI/.toolchain/gradle"
export PATH="\$JAVA_HOME/bin:\$FLUTTER_ROOT/bin:\$ANDROID_HOME/platform-tools:\$PATH"
EOF

info "Terminé"
echo "    source env.sh   puis   ./build.sh"
echo "    Tout désinstaller : rm -rf .toolchain"
du -sh "$OUTILS" 2>/dev/null || true
