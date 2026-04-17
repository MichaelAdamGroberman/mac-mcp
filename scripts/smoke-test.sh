#!/usr/bin/env bash
#
# MCP stdio smoke test: send initialize + tools/list to the binary
# and verify the response includes our ~24 tools.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Prefer signed .app binary; fall back to debug build for fast iteration.
BIN="$ROOT/dist/MacMCP.app/Contents/MacOS/MacMCP"
if [ ! -x "$BIN" ]; then
    BIN="$(swift build --show-bin-path)/MacMCP"
fi
[ -x "$BIN" ] || { echo "no MacMCP binary; run swift build or scripts/build-app.sh"; exit 1; }

REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"smoke","version":"0"},"capabilities":{}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

echo "==> piping initialize + tools/list to $BIN"
# Hold stdin open with sleep so the non-blocking reader has time to drain.
RESP=$( ( printf '%s\n' "$REQ"; sleep 2 ) | MAC_MCP_LOG_LEVEL=warn "$BIN" 2>/dev/null )

COUNT=$(printf '%s' "$RESP" | grep -o '"name":"[a-z_]*"' | sort -u | wc -l | tr -d ' ')
echo "==> unique tool names returned: $COUNT (expecting ≥56)"

# Show first response line and the full tool sampling
printf '%s\n' "$RESP" | head -1 | head -c 200; echo "..."
printf '%s\n' "$RESP" | tail -1 | grep -o '"name":"[a-z_]*"' | sort -u

[ "$COUNT" -ge 56 ] || { echo "FAIL: too few tools (expected ≥56, got $COUNT)"; exit 1; }
echo "OK"
