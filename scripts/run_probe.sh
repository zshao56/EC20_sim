#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${SDKROOT:-}" ]]; then
    EC20_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [[ -d "$EC20_SDK" ]]; then
        export SDKROOT="$EC20_SDK"
    fi
fi

echo "==> Building and running EC20 diagnostic probe CLI..."
cd "${ROOT_DIR}"
swift build --product ec20-cli

echo "==> Executing ec20-cli against connected Quectel EC20 hardware..."
"${ROOT_DIR}/.build/debug/ec20-cli" "$@"
