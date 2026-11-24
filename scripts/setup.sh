#!/usr/bin/env bash
# TVBoxMac 一键环境安装 + 构建（Mac 本地入口）
#
# 默认行为（不加参数）：安装/检查 CatVod 所需的全部依赖，并安装托管 Android
# 运行时（SDK 组件 + AVD + Bridge APK），然后构建、打包 .app。
#
# 用法:
#   bash scripts/setup.sh                 # 全量：Android 运行时依赖 + Bridge + 构建
#   bash scripts/setup.sh --test          # 额外跑单测（81 个）
#   bash scripts/setup.sh --run           # 构建后直接运行
#   bash scripts/setup.sh --no-android    # 只构建 App（CatVod/JS 源可用，jar 源不可用）
#   bash scripts/setup.sh --with-bridge   # 兼容参数：默认已会构建 Bridge
#
# 只有 jar/Dex（csp_ / type=3）源需要 Android 运行时；CatVod 与 JS 源不需要。
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_TEST=0
RUN_APP=0
SETUP_ANDROID=1
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TEST=1 ;;
    --run) RUN_APP=1 ;;
    --android) SETUP_ANDROID=1 ;;
    --no-android) SETUP_ANDROID=0 ;;
    --with-bridge) ;;   # 兼容旧参数：默认已构建 Bridge
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "❌ $1" >&2; exit 1; }
warn() { echo "⚠️  $1" >&2; }
ok()   { echo "✅ $1"; }

# 1. macOS 版本（需 13+）
SW_VERS=$(sw_vers -productVersion)
SW_MAJOR=${SW_VERS%%.*}
[ "$SW_MAJOR" -ge 13 ] && ok "macOS $SW_VERS (≥13)" \
  || fail "macOS $SW_VERS 过低，需 13 Ventura 及以上"

# 2. Swift 工具链
if ! command -v swift >/dev/null 2>&1; then
  fail "未找到 swift。先装 Command Line Tools: xcode-select --install
（有 Xcode 则: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer）"
fi
SWIFT_VER=$(swift --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
if [ "$(printf '%s\n5.9\n' "$SWIFT_VER" | sort -V | head -1)" = "5.9" ]; then
  ok "Swift $SWIFT_VER (≥5.9)"
else
  fail "Swift $SWIFT_VER 过低，需 5.9+（升级 Xcode / CLT）"
fi

# 3. git
command -v git >/dev/null && ok "git $(git --version | awk '{print $3}')"

# 4. Android 运行时依赖（默认安装；--no-android 可跳过）
BRIDGE_APK=".build/AndroidDexBridge-release.apk"
if [ "$SETUP_ANDROID" -eq 1 ]; then
  echo ""
  echo "---- 安装/检查 Android 运行时依赖（jar 源需要）----"
  if ! bash scripts/install-android-runtime.sh --yes; then
    warn "Android 运行时依赖未安装完整；CatVod/JS 源仍可用，jar 源将不可用"
  fi
fi

# 5. Bridge APK（缺失时尝试构建：需要 JDK 17）
find_jdk17() {
  for candidate in \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"; do
    [ -x "$candidate/bin/java" ] && { echo "$candidate"; return 0; }
  done
  local jh
  jh=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
  if [ -n "$jh" ] && "$jh/bin/java" -version 2>&1 | head -1 | grep -q '"17\.'; then
    echo "$jh"; return 0
  fi
  return 1
}

if [ "$SETUP_ANDROID" -eq 1 ] && [ ! -f "$BRIDGE_APK" ]; then
  echo ""
  echo "---- 构建 Bridge APK（首次需要 JDK 17 + 联网拉 Gradle，约几分钟）----"
  if JDK17=$(find_jdk17); then
    if JAVA_HOME="$JDK17" bash scripts/build-android-bridge.sh; then
      ok "Bridge APK 已构建: $BRIDGE_APK"
    else
      warn "Bridge 构建失败；jar 源将不可用。可稍后重试: JAVA_HOME=$JDK17 bash scripts/build-android-bridge.sh"
    fi
  else
    warn "未找到 JDK 17，跳过 Bridge 构建。安装方法: brew install openjdk@17"
    warn "没有 Bridge 时 CatVod/JS 源仍可用，只有 csp_/jar 源不可用"
  fi
elif [ -f "$BRIDGE_APK" ]; then
  ok "Bridge APK 已存在: $BRIDGE_APK"
fi

# 6. 构建
echo ""
echo "---- swift build -c release ----"
swift build -c release

# 7. 可选单测
if [ "$RUN_TEST" -eq 1 ]; then
  echo "---- swift test ----"
  swift test
fi

# 8. 打 .app
bash scripts/make-app-bundle.sh

echo ""
echo "🎉 完成。TVBoxMac.app 在项目根目录；zip 在 dist/TVBoxMac.app.zip"
if [ "$SETUP_ANDROID" -eq 1 ] && [ ! -f "$BRIDGE_APK" ]; then
  echo "   ⚠️ 本次没有 Bridge APK：CatVod/JS 源可用，csp_/jar 源不可用。"
fi
if [ "$RUN_APP" -eq 1 ]; then
  xattr -d com.apple.quarantine TVBoxMac.app 2>/dev/null || true
  open TVBoxMac.app
fi
