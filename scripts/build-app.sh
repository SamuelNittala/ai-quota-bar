#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/AIQuotaBar.app"
VERSION="${VERSION:-0.1.0}"
CREATE_DMG=0

for arg in "$@"; do
    case "$arg" in
        --dmg) CREATE_DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

cd "$ROOT_DIR"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$ROOT_DIR/.build/apple/Products/Release/AIQuotaBar"
else
    swift build -c release
    BIN_PATH="$ROOT_DIR/.build/release/AIQuotaBar"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/AIQuotaBar"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/1\)/{print $2; exit}' || true)"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing AIQuotaBar.app with identity: $CODESIGN_IDENTITY"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
    echo "Warning: No codesigning identity found; using ad-hoc signature (-)."
    codesign --force --sign - "$APP_DIR"
fi

echo "Built: $APP_DIR (version $VERSION)"

if [[ "$CREATE_DMG" == "1" ]]; then
    DMG_PATH="$ROOT_DIR/build/AIQuotaBar-${VERSION}.dmg"
    STAGE_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGE_DIR"' EXIT
    cp -R "$APP_DIR" "$STAGE_DIR/AIQuotaBar.app"
    ln -s /Applications "$STAGE_DIR/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -volname "AIQuotaBar" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
    echo "Packaged: $DMG_PATH"
fi
