#!/usr/bin/env bash
# 安装「托管 Android 运行时」所需的本机依赖（仅 jar/Dex 源需要）。
#
# 做四件事：
#   1. 确保存在 Android SDK 的 cmdline-tools（没有就下载官方 zip）
#   2. 用 sdkmanager 安装 platform-tools / emulator / build-tools / 系统镜像
#   3. 在 App Support 下创建 AVD（默认 TVBoxMac_Runtime）
#   4. 可选：构建并签名 Bridge APK（需要 JDK 17，且会联网拉 Gradle 依赖）
#
# 用法:
#   bash scripts/install-android-runtime.sh [--yes] [--with-bridge] [--avd-name NAME]
#
# 环境变量:
#   ANDROID_SDK_ROOT          默认 ~/Library/Android/sdk
#   TVBOX_CMDLINE_TOOLS_URL   cmdline-tools 下载地址（默认 Google 官方 mac 包）
#   TVBOX_AVD_NAME            默认 TVBoxMac_Runtime
#
# 不会删除任何已有 SDK 组件；已安装的会跳过。
set -euo pipefail

SDK=${ANDROID_SDK_ROOT:-"$HOME/Library/Android/sdk"}
AVD_NAME=${TVBOX_AVD_NAME:-TVBoxMac_Runtime}
SYSTEM_IMAGE="system-images;android-35;google_apis;arm64-v8a"
CMDLINE_URL=${TVBOX_CMDLINE_TOOLS_URL:-"https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip"}
SUPPORT="$HOME/Library/Application Support/TVBoxMac/managed-android-runtime"
AVD_HOME="$SUPPORT/avd"
USER_HOME_ANDROID="$SUPPORT/home"

ASSUME_YES=0
WITH_BRIDGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --with-bridge) WITH_BRIDGE=1 ;;
    --avd-name) AVD_NAME="$2"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1" >&2; }
fail() { echo "❌ $1" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || fail "托管运行时只支持 Apple Silicon（当前 $(uname -m)）"

# ---------------------------------------------------------------- cmdline-tools
find_sdkmanager() {
  for p in "$SDK"/cmdline-tools/latest/bin/sdkmanager "$SDK"/cmdline-tools/*/bin/sdkmanager; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

SDKMANAGER="$(find_sdkmanager || true)"
if [ -z "$SDKMANAGER" ]; then
  echo "---- 安装 Android cmdline-tools 到 $SDK ----"
  command -v curl >/dev/null || fail "需要 curl 下载 cmdline-tools"
  command -v unzip >/dev/null || fail "需要 unzip 解压 cmdline-tools"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -L --fail --connect-timeout 15 --max-time 600 -o "$TMP/tools.zip" "$CMDLINE_URL"
  unzip -q "$TMP/tools.zip" -d "$TMP/out"
  mkdir -p "$SDK/cmdline-tools"
  rm -rf "$SDK/cmdline-tools/latest"
  mv "$TMP/out/cmdline-tools" "$SDK/cmdline-tools/latest"
  SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
  ok "cmdline-tools 已安装"
else
  ok "已找到 sdkmanager: $SDKMANAGER"
fi

export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"

# ---------------------------------------------------------------- SDK 组件
# 直接用文件系统判断组件是否已安装：新版 sdkmanager 已弃用且默认无输出。
pkg_installed() {
  case "$1" in
    "platform-tools") [ -x "$SDK/platform-tools/adb" ] ;;
    "emulator") [ -x "$SDK/emulator/emulator" ] ;;
    "build-tools;35.0.0") [ -x "$SDK/build-tools/35.0.0/apksigner" ] ;;
    "platforms;android-35") [ -d "$SDK/platforms/android-35" ] ;;
    "$SYSTEM_IMAGE") [ -d "$SDK/system-images/android-35/google_apis/arm64-v8a" ] ;;
    *) return 1 ;;
  esac
}

MISSING=()
for pkg in "platform-tools" "emulator" "build-tools;35.0.0" "platforms;android-35" "$SYSTEM_IMAGE"; do
  if pkg_installed "$pkg"; then
    ok "$pkg 已安装"
  else
    MISSING+=("$pkg")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "---- 安装: ${MISSING[*]} ----"
  if [ "$ASSUME_YES" -eq 0 ]; then
    printf "将下载约 1.5GB，继续？[y/N] "
    read -r ans; [ "${ans:-}" = "y" ] || [ "${ans:-}" = "Y" ] || fail "已取消"
  fi
  yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
  if [ -x "$SDK/cmdline-tools/latest/bin/android" ]; then
    "$SDK/cmdline-tools/latest/bin/android" --sdk="$SDK" sdk install "${MISSING[@]}"
  else
    "$SDKMANAGER" --install "${MISSING[@]}"
  fi
  ok "SDK 组件安装完成"
fi

[ -x "$SDK/platform-tools/adb" ] || fail "adb 缺失：$SDK/platform-tools/adb"
[ -x "$SDK/emulator/emulator" ] || fail "emulator 缺失：$SDK/emulator/emulator"

# ---------------------------------------------------------------- AVD
mkdir -p "$AVD_HOME" "$USER_HOME_ANDROID"
export ANDROID_AVD_HOME="$AVD_HOME"
export ANDROID_USER_HOME="$USER_HOME_ANDROID"
export ANDROID_EMULATOR_HOME="$USER_HOME_ANDROID"

if [ -f "$AVD_HOME/$AVD_NAME.ini" ]; then
  ok "AVD 已存在: $AVD_NAME"
else
  echo "---- 创建 AVD $AVD_NAME ----"
  AVDMANAGER=""
  for p in "$SDK"/cmdline-tools/latest/bin/avdmanager "$SDK"/cmdline-tools/*/bin/avdmanager; do
    [ -x "$p" ] && AVDMANAGER="$p" && break
  done
  CREATED=0
  if [ -n "$AVDMANAGER" ]; then
    if echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d pixel_5 --force >/dev/null 2>&1; then
      CREATED=1
    fi
  fi
  if [ "$CREATED" -eq 0 ]; then
    # 兜底：手写 AVD 文件结构（avdmanager 在部分机器上枚举不到系统镜像）
    warn "avdmanager 创建失败，改用手写 AVD 配置"
    mkdir -p "$AVD_HOME/$AVD_NAME.avd"
    cat > "$AVD_HOME/$AVD_NAME.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_HOME/$AVD_NAME.avd
path.rel=avd/$AVD_NAME.avd
target=android-35
EOF
    cat > "$AVD_HOME/$AVD_NAME.avd/config.ini" <<EOF
avd.ini.encoding = UTF-8
disk.dataPartition.size = 6442450944
hw.cpu.arch = arm64
hw.cpu.ncore = 4
hw.keyboard = yes
hw.lcd.density = 420
hw.lcd.height = 1920
hw.lcd.width = 1080
hw.ramSize = 2048
image.sysdir.1 = system-images/android-35/google_apis/arm64-v8a/
tag.display = Google APIs
tag.id = google_apis
EOF
  fi
  [ -f "$AVD_HOME/$AVD_NAME.ini" ] || fail "AVD 创建失败"
  ok "AVD 已创建: $AVD_NAME"
fi

# ---------------------------------------------------------------- Bridge APK（可选）
if [ "$WITH_BRIDGE" -eq 1 ]; then
  if [ -f ".build/AndroidDexBridge-release.apk" ]; then
    ok "Bridge APK 已存在: .build/AndroidDexBridge-release.apk"
  else
    echo "---- 构建 Bridge APK（需要 JDK 17 + Gradle 联网）----"
    JDK17=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
    [ -n "$JDK17" ] || fail "未找到 JDK 17。可执行: brew install openjdk@17"
    JAVA_HOME="$JDK17" bash scripts/build-android-bridge.sh
  fi
else
  echo "ℹ️  Bridge APK 未在本次安装中构建（setup.sh 默认会在缺失时自动构建）"
fi

echo ""
echo "🎉 Android 运行时依赖就绪："
echo "   SDK:   $SDK"
echo "   AVD:   $AVD_HOME/$AVD_NAME.ini"
echo "   Bridge: $([ -f .build/AndroidDexBridge-release.apk ] && echo 已存在 || echo 未构建)"
echo "   下一步: bash scripts/setup.sh --run，或在设置里开启“启动时预热 Android Runtime”"
