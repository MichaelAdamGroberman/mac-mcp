#!/usr/bin/env bash
#
# Build, sign, and pack mac-mcp.mcpb (Claude Desktop Extension bundle).
# Output: dist/mac-mcp.mcpb
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/staging"
MCPB="$DIST/mac-mcp.mcpb"

# 1) Build & sign the .app
"$ROOT/scripts/build-app.sh"

# 2) Stage the .mcpb layout
echo "==> staging .mcpb layout"
rm -rf "$STAGE" "$MCPB"
mkdir -p "$STAGE/server"
cp -R "$DIST/MacMCP.app" "$STAGE/server/MacMCP.app"
cp "$ROOT/manifest.json" "$STAGE/manifest.json"

if [ -f "$ROOT/icon.png" ]; then
    cp "$ROOT/icon.png" "$STAGE/icon.png"
else
    echo "    (no icon.png — Claude Desktop will show a default icon)"
fi

# 3) Zip into .mcpb
echo "==> packing $MCPB"
( cd "$STAGE" && zip -r -y -q "$MCPB" . )

echo
echo "OK: $MCPB"
echo
echo "To install:"
echo "  open '$MCPB'"
echo "or drag it into Claude Desktop's Settings → Extensions."
