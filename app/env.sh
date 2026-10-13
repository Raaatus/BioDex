# Généré par installe_toolchain.sh — à sourcer pour utiliser la chaîne confinée :
#     source env.sh
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export JAVA_HOME="$ICI/.toolchain/jdk"
export FLUTTER_ROOT="$ICI/.toolchain/flutter"
export ANDROID_HOME="$ICI/.toolchain/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PUB_CACHE="$ICI/.toolchain/pub-cache"
# Gradle range ses caches ici plutôt que dans ~/.gradle, pour que la
# suppression de .toolchain ne laisse vraiment rien derrière.
export GRADLE_USER_HOME="$ICI/.toolchain/gradle"
export PATH="$JAVA_HOME/bin:$FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$PATH"
