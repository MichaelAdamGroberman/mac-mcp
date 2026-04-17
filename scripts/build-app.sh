#!/usr/bin/env bash
#
# Build the universal MacMCP binary, bundle it into MacMCP.app,
# and codesign with the Developer ID Application identity.
#
# Output: dist/MacMCP.app
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/MacMCP.app"

SIGN_IDENTITY="${MACMCP_SIGN_IDENTITY:-Developer ID Application: Iosif Groberman (K8TEAW9B4H)}"
ENTITLEMENTS="$ROOT/Resources/MacMCP.entitlements"
INFO_PLIST="$ROOT/Resources/Info.plist"

echo "==> swift build (release, universal arm64+x86_64)"
swift build \
    -c release \
    --arch arm64 \
    --arch x86_64 \
    --product MacMCP

# SwiftPM puts universal binaries under .build/apple/Products/Release/
BIN="$ROOT/.build/apple/Products/Release/MacMCP"
if [ ! -x "$BIN" ]; then
    # fall back to single-arch path
    BIN="$ROOT/.build/release/MacMCP"
fi
[ -x "$BIN" ] || { echo "build output not found"; exit 1; }

echo "==> bundling MacMCP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacMCP"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
[ -f "$ROOT/icon.png" ] && cp "$ROOT/icon.png" "$APP/Contents/Resources/icon.png" || true

echo "==> codesigning with: $SIGN_IDENTITY"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

echo "==> verifying signature"
codesign -dvv "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "OK: $APP"
