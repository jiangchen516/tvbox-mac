#!/usr/bin/env bash
# 把 SwiftPM 构建出的 TVBoxMac 可执行文件打包成 TVBoxMac.app（无签名分发，ad-hoc 签名）。
# 用法: bash scripts/make-app-bundle.sh
set -euo pipefail

cd "$(dirname "$0")/.."

BIN=".build/release/TVBoxMac"
APP="TVBoxMac.app"

if [ ! -f "$BIN" ]; then
  echo "error: 找不到可执行文件 $BIN（请先运行 swift build -c release）" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TVBoxMac"
chmod +x "$APP/Contents/MacOS/TVBoxMac"

# Optional Java/Dex compatibility component. Native CatVod/JS builds remain
# usable when the Bridge APK has not been built yet.
BRIDGE_APK=".build/AndroidDexBridge-release.apk"
if [ -f "$BRIDGE_APK" ]; then
  cp "$BRIDGE_APK" "$APP/Contents/Resources/AndroidDexBridge-release.apk"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>TVBoxMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.tvboxmac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TVBoxMac</string>
    <key>CFBundleDisplayName</key>
    <string>TVBoxMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string></string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# ad-hoc 签名（本地运行 / 个人分发足够；如需正式分发请改用开发者证书）
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
else
  echo "warning: codesign 不可用，跳过签名" >&2
fi

# 打成 zip（顶层即 TVBoxMac.app/），分发/CI 上传用
# 注意：upload-artifact 的 path 指目录时只上传其【内容】，会丢 .app 外壳，
# 所以产物是单文件 zip，上传/下载后解压即得正确的 .app
mkdir -p dist
rm -f "dist/TVBoxMac.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/TVBoxMac.app.zip"

echo "OK: $APP + dist/TVBoxMac.app.zip"
