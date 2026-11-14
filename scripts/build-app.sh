#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/AIQuotaBar.app"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/AIQuotaBar" "$APP_DIR/Contents/MacOS/AIQuotaBar"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/1\)/{print $2; exit}' || true)"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing AIQuotaBar.app with identity: $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
    echo "Warning: No codesigning identity found; using ad-hoc signature (-)."
    echo "macOS Keychain may re-prompt after rebuilds until a local Code Signing certificate is configured."
    codesign --force --sign - "$APP_DIR"
fi

echo "Built: $APP_DIR"
