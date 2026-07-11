#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT_DIR="${1:-${ROOT}/.build}"
APP="${OUTPUT_DIR}/ChatGPT Proxy.app"
CONTENTS="${APP}/Contents"
RESOURCES="${CONTENTS}/Resources"
MACOS="${CONTENTS}/MacOS"
VERSION="2.1.0"
BUILD="11"

rm -rf "${APP}"
mkdir -p "${MACOS}" "${RESOURCES}"

/usr/bin/clang -O2 -Wall -Wextra -Werror -pthread \
  "${ROOT}/NativeSocksHTTPBridge.c" \
  -o "${RESOURCES}/chatgpt-socks-http-bridge"

/usr/bin/swiftc -O -framework AppKit \
  "${ROOT}/ChatGPTProxyLauncher.swift" \
  -o "${MACOS}/ChatGPTProxyLauncher"

cp "${ROOT}/chatgpt-proxy-launch.sh" "${RESOURCES}/"
cp "${ROOT}/chatgpt-proxy.conf.example" "${RESOURCES}/"
chmod +x "${RESOURCES}/chatgpt-proxy-launch.sh"

ICONSET="${OUTPUT_DIR}/ChatGPTProxy.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
for spec in 16 32 128 256 512; do
  /usr/bin/sips -z "${spec}" "${spec}" "${ROOT}/CodexProxyIcon.png" --out "${ICONSET}/icon_${spec}x${spec}.png" >/dev/null
  double=$((spec * 2))
  /usr/bin/sips -z "${double}" "${double}" "${ROOT}/CodexProxyIcon.png" --out "${ICONSET}/icon_${spec}x${spec}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>ChatGPT Proxy</string>
  <key>CFBundleExecutable</key><string>ChatGPTProxyLauncher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.chatgpt.proxy.launcher</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ChatGPT Proxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>ChatGPT Proxy connects to your local SOCKS5 proxy to start ChatGPT with per-app proxy settings.</string>
</dict></plist>
PLIST

/usr/bin/codesign --force --deep --sign - "${APP}"
echo "Built: ${APP}"
