#!/usr/bin/env bash
# TVBoxMac 环境检查 + 构建（Mac 本地开发入口）
# 用法: bash scripts/setup.sh [--test] [--run] [--android] [--with-bridge]
#   --test         构建后跑单测
#   --run          构建后直接运行应用
#   --android      先安装/检查托管 Android 运行时依赖（SDK 组件 + AVD）
#   --with-bridge  与 --android 同用：额外构建并签名 Bridge APK（需要 JDK 17）
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_TEST=0
RUN_APP=0
SETUP_ANDROID=0
WITH_BRIDGE=0
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TEST=1 ;;
    --run) RUN_APP=1 ;;
    --android) SETUP_ANDROID=1 ;;
    --with-bridge) WITH_BRIDGE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "❌ $1" >&2; exit 1; }
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

# 4. 可选：Android 运行时依赖（只有 jar/Dex 源需要）
if [ "$SETUP_ANDROID" -eq 1 ]; then
  echo "---- 安装/检查 Android 运行时依赖 ----"
  EXTRA=()
  [ "$WITH_BRIDGE" -eq 1 ] && EXTRA+=(--with-bridge)
  bash scripts/install-android-runtime.sh --yes ${EXTRA[@]+"${EXTRA[@]}"}
  echo ""
fi

# 5. 构建
echo "---- swift build -c release ----"
swift build -c release

# 6. 可选步骤
if [ "$RUN_TEST" -eq 1 ]; then
  echo "---- swift test ----"
  swift test
fi

# 7. 打 .app
bash scripts/make-app-bundle.sh

echo ""
echo "🎉 完成。TVBoxMac.app 在项目根目录；zip 在 dist/TVBoxMac.app.zip"
if [ "$RUN_APP" -eq 1 ]; then
  xattr -d com.apple.quarantine TVBoxMac.app 2>/dev/null || true
  open TVBoxMac.app
fi
