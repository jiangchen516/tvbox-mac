#!/usr/bin/env bash
set -euo pipefail

# Build the optional Android Dex Bridge from the upstream GPL project.
# The source is fetched outside this repository and is never copied into the
# Swift target. The resulting APK is an input to a separately reviewed bundle.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TVBOX_ANDROID_BRIDGE_WORK:-"$ROOT/.build/android-bridge-source"}
REPO=${TVBOX_ANDROID_BRIDGE_REPO:-https://github.com/yaolin-dev/OKVideoMac.git}
REV=${TVBOX_ANDROID_BRIDGE_REV:-25155f52fb8c416f3245c9a829a93175dec9857b}
APK="$WORK/OKVideoMac/Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release-unsigned.apk"
SIGNED="$ROOT/.build/AndroidDexBridge-release.apk"

: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
: "${ANDROID_SDK_ROOT:=$HOME/Library/Android/sdk}"
export JAVA_HOME ANDROID_SDK_ROOT

command -v git >/dev/null || { echo "error: git is required" >&2; exit 1; }
[ -x "$JAVA_HOME/bin/java" ] || { echo "error: JDK 17 not found at $JAVA_HOME" >&2; exit 1; }
[ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ] || { echo "error: Android SDK not found at $ANDROID_SDK_ROOT" >&2; exit 1; }

mkdir -p "$(dirname "$WORK")"
if [ ! -d "$WORK/.git" ]; then
    git clone "$REPO" "$WORK"
fi
git -C "$WORK" fetch --depth 1 origin "$REV"
git -C "$WORK" checkout --detach "$REV"

BRIDGE_DIR="$WORK/OKVideoMac/Helpers/AndroidDexBridge"
[ -x "$BRIDGE_DIR/gradlew" ] || { echo "error: Bridge Gradle wrapper missing" >&2; exit 1; }
(
    cd "$BRIDGE_DIR"
    ./gradlew --no-daemon :app:assembleRelease
)

[ -f "$APK" ] || { echo "error: unsigned Bridge APK was not produced" >&2; exit 1; }
mkdir -p "$(dirname "$SIGNED")"

KEYSTORE=${TVBOX_ANDROID_BRIDGE_KEYSTORE:-"$ROOT/.build/tvbox-bridge.keystore"}
ALIAS=${TVBOX_ANDROID_BRIDGE_KEY_ALIAS:-tvboxmac}
STORE_PASSWORD=${TVBOX_ANDROID_BRIDGE_STORE_PASSWORD:-tvboxmac-local}
KEY_PASSWORD=${TVBOX_ANDROID_BRIDGE_KEY_PASSWORD:-tvboxmac-local}
if [ ! -f "$KEYSTORE" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KEYSTORE" \
        -storepass "$STORE_PASSWORD" -keypass "$KEY_PASSWORD" \
        -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=TVBoxMac local Android Bridge, OU=TVBoxMac, O=TVBoxMac, C=US"
fi

APKSIGNER="$ANDROID_SDK_ROOT/build-tools/35.0.0/apksigner"
[ -x "$APKSIGNER" ] || { echo "error: apksigner 35.0.0 not found" >&2; exit 1; }
"$APKSIGNER" sign --ks "$KEYSTORE" \
    --ks-key-alias "$ALIAS" \
    --ks-pass "pass:$STORE_PASSWORD" \
    --key-pass "pass:$KEY_PASSWORD" \
    --out "$SIGNED" "$APK"
"$APKSIGNER" verify --verbose "$SIGNED"

echo "OK: $SIGNED"
