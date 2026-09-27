#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="${EC20_APP_NAME:-EC20Companion.app}"
APP_DIR="${ROOT_DIR}/${APP_NAME}"
INSTALL_APP=0
LAUNCH_APP=0

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_APP=1 ;;
        --launch) INSTALL_APP=1; LAUNCH_APP=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# This CLT installation has a macOS 27 SDK without the SwiftUI State macro
# plugin. The macOS 26.5 SDK builds the SwiftUI source correctly. The bundled
# Homebrew libusb currently requires macOS 26 or newer.
if [[ -z "${SDKROOT:-}" ]]; then
    EC20_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [[ -d "$EC20_SDK" ]]; then
        export SDKROOT="$EC20_SDK"
    fi
fi

cd "$ROOT_DIR"
echo "==> Building EC20Companion (SDKROOT=${SDKROOT:-default})"
swift build -c release --product EC20App

CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
BIN_PATH="${ROOT_DIR}/.build/release/EC20App"

if [[ -d "$APP_DIR" ]]; then
    /usr/bin/find "$APP_DIR" -depth -delete
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
/usr/bin/ditto "$BIN_PATH" "$MACOS_DIR/EC20App"

if [[ ! -f "${ROOT_DIR}/Assets/AppIcon.icns" ]]; then
    swift "${ROOT_DIR}/scripts/generate_icon.swift" "$ROOT_DIR"
fi
/usr/bin/ditto "${ROOT_DIR}/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Keep libusb inside the bundle so the installed app does not need Homebrew.
LIBUSB_PATH="$(/usr/bin/otool -L "$BIN_PATH" | /usr/bin/awk '/libusb-1\.0\.0\.dylib/ { print $1; exit }')"
if [[ -z "$LIBUSB_PATH" || ! -f "$LIBUSB_PATH" ]]; then
    echo "Unable to find linked libusb dylib: $LIBUSB_PATH" >&2
    exit 1
fi
/usr/bin/ditto "$LIBUSB_PATH" "$FRAMEWORKS_DIR/libusb-1.0.0.dylib"
/usr/bin/install_name_tool -change "$LIBUSB_PATH" \
    "@executable_path/../Frameworks/libusb-1.0.0.dylib" "$MACOS_DIR/EC20App"
/usr/bin/install_name_tool -id "@rpath/libusb-1.0.0.dylib" \
    "$FRAMEWORKS_DIR/libusb-1.0.0.dylib"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>EC20App</string>
    <key>CFBundleIdentifier</key><string>com.quectel.ec20companion</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>EC20 蜂窝通信助理</string>
    <key>CFBundleDisplayName</key><string>EC20 助理</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于通过 EC20 模块接打电话时传输麦克风语音。</string>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
echo "==> Packaged $APP_DIR"

if [[ "$INSTALL_APP" == 1 ]]; then
    DESTINATION="/Applications/EC20Companion.app"
    if [[ -d "$DESTINATION" ]]; then
        /usr/bin/find "$DESTINATION" -depth -delete
    fi
    /usr/bin/ditto "$APP_DIR" "$DESTINATION"
    /usr/bin/codesign --verify --deep --strict "$DESTINATION"
    echo "==> Installed $DESTINATION"
    if [[ "$LAUNCH_APP" == 1 ]]; then
        /usr/bin/open "$DESTINATION"
    fi
fi
