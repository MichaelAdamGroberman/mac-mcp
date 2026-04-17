#!/usr/bin/env bash
#
# Cut a v* tag, build/sign/(notarize)/pack, and create a GitHub release with the
# .mcpb attached. If the notary credentials profile exists, runs notarize.sh
# first; otherwise releases the codesigned-but-not-notarized .mcpb and adds a
# note in the release body.
#
# Usage: scripts/release.sh v0.1.0
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: scripts/release.sh vX.Y.Z"; exit 1; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag must look like v0.1.0"; exit 1; }

PROFILE="${MACMCP_NOTARY_PROFILE:-macmcp-notary}"

echo "==> build & sign"
"$ROOT/scripts/build-app.sh"

NOTARIZED="no"
if security find-generic-password -s "com.apple.gke.notary.tool" -a "$PROFILE" >/dev/null 2>&1; then
    echo "==> notary profile '$PROFILE' present — notarizing"
    "$ROOT/scripts/notarize.sh"
    NOTARIZED="yes"
else
    echo "==> notary profile '$PROFILE' NOT present — releasing without notarization"
    "$ROOT/scripts/pack-mcpb.sh"
fi

echo "==> tagging $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

NOTES_FILE="$(mktemp)"
{
    echo "## mac-mcp $TAG"
    echo
    echo "Native macOS control for Claude Desktop. 32 typed allow-listed tools."
    echo
    echo "**Install:** download \`mac-mcp.mcpb\` below, double-click, accept the Claude Desktop install dialog."
    echo
    echo "### Signing"
    echo
    if [ "$NOTARIZED" = "yes" ]; then
        echo "- Code-signed with Developer ID Application + hardened runtime"
        echo "- **Notarized + stapled** by Apple"
    else
        echo "- Code-signed with Developer ID Application + hardened runtime"
        echo "- ⚠️  Notarization pending — Gatekeeper may show \"unidentified developer\" on first launch on machines other than the build host. Right-click → Open to bypass, or wait for the next release."
    fi
    echo
    echo "### TCC"
    echo
    echo "On first tool call you'll be prompted once for Accessibility and Automation grants. Because the binary is code-signed with a stable Developer ID identity, those grants persist across rebuilds."
    echo
    echo "See [README](https://github.com/MichaelAdamGroberman/mac-mcp#readme) for the full tool list."
} > "$NOTES_FILE"

echo "==> creating GitHub release"
gh release create "$TAG" \
    "dist/mac-mcp.mcpb" \
    --title "mac-mcp $TAG" \
    --notes-file "$NOTES_FILE"

rm -f "$NOTES_FILE"
echo
echo "OK: released $TAG"
echo "  https://github.com/MichaelAdamGroberman/mac-mcp/releases/tag/$TAG"
