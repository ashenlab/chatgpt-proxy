#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUTPUT_DIR="${1:-${ROOT}/.build}"
APP="${OUTPUT_DIR}/ChatGPT Proxy.app"
CONTENTS="${APP}/Contents"
RESOURCES="${CONTENTS}/Resources"
MACOS="${CONTENTS}/MacOS"
VERSION="2.1.7"
BUILD="30"
DEPLOYMENT_TARGET="12.0"
MODULE_CACHE="${CHATGPT_PROXY_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/chatgpt-proxy-module-cache}"

rm -rf "${APP}"
mkdir -p "${MACOS}" "${RESOURCES}" "${MODULE_CACHE}"

/usr/bin/clang -O2 -Wall -Wextra -Werror -pthread \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  "${ROOT}/NativeSocksHTTPBridge.c" \
  -o "${RESOURCES}/chatgpt-socks-http-bridge"

/usr/bin/swiftc -O -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -module-cache-path "${MODULE_CACHE}" \
  -framework AppKit \
  "${ROOT}/ChatGPTProxyLauncher.swift" \
  -o "${MACOS}/ChatGPTProxyLauncher"

/usr/bin/swiftc -O -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -module-cache-path "${MODULE_CACHE}" \
  -framework AppKit \
  "${ROOT}/ChatGPTLaunchHelper.swift" \
  -o "${RESOURCES}/chatgpt-launch-helper"

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
rm -rf "${ICONSET}"

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

for executable in "${MACOS}/ChatGPTProxyLauncher" "${RESOURCES}/chatgpt-launch-helper" "${RESOURCES}/chatgpt-socks-http-bridge"; do
  minimum_version="$(/usr/bin/vtool -show-build "${executable}" | /usr/bin/awk '/minos/{print $2; exit}')"
  if [[ "${minimum_version}" != "${DEPLOYMENT_TARGET}" ]]; then
    print -u2 -- "Unexpected minimum macOS version for ${executable}: ${minimum_version:-unknown}"
    exit 1
  fi
done

echo "Built: ${APP}"
