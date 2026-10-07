#!/usr/bin/env bash
# Build wer for Android (arm64): build/wer-<version>-android-arm64.apk, and
# for a release also the App Bundle Google Play takes (.aab).
#
#   scripts/build-android.sh [debug|release]
#
# Needs the Android SDK (ANDROID_HOME, else /opt/android-sdk or ~/Android/Sdk)
# with platform 37, build-tools 37.0.0 and NDK 30.0.16248370, and a JDK 17 or
# 21 for Gradle (JAVA_HOME, else the newest of those in /usr/lib/jvm).
# A release build is signed with the key in android/keystore.properties if
# there is one (storeFile, storePassword, keyAlias, keyPassword: see
# android/keystore.properties.example), else left unsigned.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPE="${1:-debug}"
VERSION="$(sed -n 's/^ *"version": *"\([0-9.]*\)".*/\1/p' "$ROOT/project.json")"
SDL_VERSION="${SDL_VERSION:-3.4.18}"
APP="$ROOT/android/app/src/main"

SDK="${ANDROID_HOME:-}"
if [ -z "$SDK" ]; then
	for d in /opt/android-sdk "$HOME/Android/Sdk"; do [ -d "$d/platforms" ] && SDK="$d" && break; done
fi
[ -n "$SDK" ] || { echo "Error: no Android SDK (set ANDROID_HOME)"; exit 1; }
if [ -z "${JAVA_HOME:-}" ]; then
	for v in 21 17; do [ -d "/usr/lib/jvm/java-$v-openjdk" ] && export JAVA_HOME="/usr/lib/jvm/java-$v-openjdk" && break; done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "Error: Gradle needs a JDK 17 or 21 (set JAVA_HOME)"; exit 1; }

# wer as libmain.so (builds SDL's libSDL3.so first).
cd "$ROOT"
c3c build android -O3 --trust=full >/dev/null
mkdir -p "$APP/jniLibs/arm64-v8a"
cp build/main.so "$APP/jniLibs/arm64-v8a/libmain.so"
cp deps/sdl3-android-arm64/lib/libSDL3.so "$APP/jniLibs/arm64-v8a/"
# SDL's Java side, from the same SDL release.
rm -rf "$APP/java/org/libsdl"
mkdir -p "$APP/java/org"
cp -r "deps/sdl_src-$SDL_VERSION/android-project/app/src/main/java/org/libsdl" "$APP/java/org/"

cd "$ROOT/android"
echo "sdk.dir=$SDK" > local.properties
if [ "$TYPE" != release ]; then
	./gradlew -q assembleDebug -PwerVersion="$VERSION"
	OUT="$ROOT/build/wer-$VERSION-android-arm64.apk"
	cp app/build/outputs/apk/debug/app-debug.apk "$OUT"
	echo "$OUT"
	exit 0
fi
[ -f keystore.properties ] || echo "Note: no android/keystore.properties: the release is unsigned (Google Play won't take it)"
./gradlew -q assembleRelease bundleRelease -PwerVersion="$VERSION"
OUT="$ROOT/build/wer-$VERSION-android-arm64"
cp app/build/outputs/apk/release/app-release*.apk "$OUT.apk"
cp app/build/outputs/bundle/release/app-release.aab "$OUT.aab"
echo "$OUT.apk"
echo "$OUT.aab (for Google Play)"
