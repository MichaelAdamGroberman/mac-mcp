#!/usr/bin/env bash
#
# Notarize the signed MacMCP.app with Apple's notary service, staple the
# notarization ticket onto the bundle, and repack the .mcpb.
#
# Output: dist/MacMCP.app (stapled), dist/mac-mcp.mcpb (stapled)
#
# One-time setup (stores Apple ID + app-specific password + team ID in the
# user's login keychain under the profile name "macmcp-notary"):
#
#   xcrun notarytool store-credentials macmcp-notary \
#       --apple-id "you@example.com" \
#       --team-id  "K8TEAW9B4H" \
#       --password "xxxx-xxxx-xxxx-xxxx"     # app-specific password
#
# Override the profile name with $MACMCP_NOTARY_PROFILE.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/MacMCP.app"
ZIP="$DIST/MacMCP.zip"
PROFILE="${MACMCP_NOTARY_PROFILE:-macmcp-notary}"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first"; exit 1; }

if ! security find-generic-password -s "com.apple.gke.notary.tool" -a "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
notary credentials profile '$PROFILE' not found in keychain.

One-time setup:
  xcrun notarytool store-credentials $PROFILE \\
      --apple-id "you@example.com" \\
      --team-id  "K8TEAW9B4H" \\
      --password "xxxx-xxxx-xxxx-xxxx"

(Generate the app-specific password at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords.)

Or pass a different profile name with: MACMCP_NOTARY_PROFILE=other ./scripts/notarize.sh
EOF
    exit 1
fi

echo "==> verifying $APP is signed with hardened runtime"
codesign -dvv "$APP" 2>&1 | grep -q 'flags=0x10000(runtime)' || {
    echo "FAIL: $APP is not signed with hardened runtime — run scripts/build-app.sh first"; exit 1;
}

echo "==> zipping for submission"
rm -f "$ZIP"
( cd "$DIST" && /usr/bin/ditto -c -k --keepParent MacMCP.app "$ZIP" )

echo "==> submitting to Apple notary (this may take a few minutes)"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$PROFILE" \
    --wait \
    --output-format plist > "$DIST/notarytool-result.plist" 2> "$DIST/notarytool.err" || {
    echo "notarytool failed:"
    cat "$DIST/notarytool.err"
    if grep -q '"id"' "$DIST/notarytool-result.plist" 2>/dev/null; then
        SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$DIST/notarytool-result.plist" 2>/dev/null || true)
        echo
        echo "Fetching notarization log for submission $SUBMISSION_ID..."
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
    fi
    exit 1
}

STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$DIST/notarytool-result.plist" 2>/dev/null || echo "unknown")
echo "==> notary status: $STATUS"
[ "$STATUS" = "Accepted" ] || { echo "FAIL: notarization not accepted"; exit 1; }

echo "==> stapling notarization ticket onto $APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> repacking dist/mac-mcp.mcpb with stapled .app"
STAGE="$DIST/staging"
MCPB="$DIST/mac-mcp.mcpb"
rm -rf "$STAGE" "$MCPB"
mkdir -p "$STAGE/server"
cp -R "$APP" "$STAGE/server/MacMCP.app"
cp "$ROOT/manifest.json" "$STAGE/manifest.json"
[ -f "$ROOT/icon.png" ] && cp "$ROOT/icon.png" "$STAGE/icon.png" || true
( cd "$STAGE" && zip -r -y -q "$MCPB" . )

# clean up the submission zip (the .mcpb is what ships)
rm -f "$ZIP"

echo
echo "OK: notarized + stapled"
echo "  $APP"
echo "  $MCPB"
echo
echo "Verify: spctl -a -vv -t install '$APP'  (should print: accepted source=Notarized Developer ID)"
