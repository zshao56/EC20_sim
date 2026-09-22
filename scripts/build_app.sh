#!/usr/bin/env bash
set -euo pipefail

# Build and package EC20Companion.app for macOS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Building EC20Companion in release mode..."
cd "${ROOT_DIR}"
swift build -c release --product EC20App

APP_NAME="EC20Companion.app"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Creating macOS Application Bundle: ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

BIN_PATH="${ROOT_DIR}/.build/release/EC20App"
cp "${BIN_PATH}" "${MACOS_DIR}/EC20App"

# Info.plist
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>EC20App</string>
    <key>CFBundleIdentifier</key>
    <string>com.quectel.ec20companion</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>EC20Companion</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>EC20 Companion requires access to the microphone for bidirectional Voice over USB cellular calls.</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing ${APP_DIR}..."
codesign --force --deep --sign - "${APP_DIR}"

echo "==> EC20Companion.app created successfully at ${APP_DIR}"
