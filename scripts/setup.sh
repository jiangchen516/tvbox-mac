#!/usr/bin/env bash
# TVBoxMac 环境检查 + 构建（Mac 本地开发入口）
# 用法: bash scripts/setup.sh [--test] [--run]
#   --test  构建后跑单测
#   --run   构建后直接运行应用
set -euo pipefail
cd "$(dirname "$0")/.."

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

# 4. 构建
echo "---- swift build -c release ----"
swift build -c release

# 5. 可选步骤
if [ "${1:-}" = "--test" ]; then
  echo "---- swift test ----"
  swift test
fi

# 6. 打 .app
bash scripts/make-app-bundle.sh

echo ""
echo "🎉 完成。TVBoxMac.app 在项目根目录；zip 在 dist/TVBoxMac.app.zip"
if [ "${1:-}" = "--run" ] || [ "${2:-}" = "--run" ]; then
  xattr -d com.apple.quarantine TVBoxMac.app 2>/dev/null || true
  open TVBoxMac.app
fi
