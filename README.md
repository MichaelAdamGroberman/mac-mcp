# mac-mcp

Native macOS control for Claude Desktop, packaged as a one-click `.mcpb` extension.

A Swift MCP server that exposes a typed, allow-listed surface for controlling macOS — built directly on **AppKit**, the **Accessibility API**, **NSPasteboard**, **UNUserNotificationCenter**, **CGWindowList**, and pre-compiled **OSAKit** scripts. The signed Developer ID binary gives Claude Desktop a stable TCC identity, so Accessibility and Automation grants persist across rebuilds.

## Why not Desktop Commander or `osascript-dxt`?

| | osascript-dxt | Desktop Commander | **mac-mcp** |
|---|---|---|---|
| Tool surface | 1 raw `osascript` tool | giant `run_shell` | ~24 typed allow-listed tools |
| Engine | shell `osascript` per call | shell + Node | native Cocoa + cached OSAKit |
| TCC identity | re-prompts (Node binary) | re-prompts | persistent (signed Developer ID) |
| Packaging | `.mcpb` ✅ | npm + 4 install methods | `.mcpb` ✅ |
| Audit | none | telemetry, can't fully disable | local JSONL, no telemetry |
| Escape hatch | raw AppleScript | raw shell | none, by design |

**Explicitly not provided:** `run_shell`, `run_applescript`, `eval_python`. These are the failure modes documented in the [Desktop Commander FAQ](https://github.com/wonderwhy-er/DesktopCommanderMCP/blob/main/FAQ.md) ("command blocking can be bypassed via command substitution").

## Tools (32)

- **Window/App** (7): `list_apps`, `list_windows`, `focus_app`, `focus_window`, `move_window`, `resize_window`, `set_space`
- **Finder** (6): `reveal_in_finder`, `get_finder_selection`, `set_finder_tags`, `quick_look`, `move_to_trash`, `spotlight_search`
- **System** (6): `clipboard_read`, `clipboard_write`, `notify`, `prompt_user`, `screenshot_screen`, `screenshot_window`
- **Input** (6): `mouse_move`, `mouse_click`, `mouse_drag`, `mouse_scroll`, `key_press`, `type_text` — CGEvent-based; bounded to active displays, drag capped at 4096 px/axis, type capped at 10k chars.
- **Apps** (5): `mail`, `calendar`, `messages`, `safari`, `notes` — each accepts a typed `action` enum.
- **Terminal** (1): `terminal` — drives **iTerm2** or **Terminal.app** (`target=iterm|terminal`) with `open_window`, `run_command`, `send_text`, `get_active_text`, `list_sessions`.
- **iPhone Mirroring** (1): `iphone_mirror` — `launch`, `focus`, `type_text`, `screenshot`, `get_window` for macOS Sonoma+'s iPhone Mirroring app. Tap interactions use `mouse_click` against the window's reported bounds.

Each tool has a strict JSON schema; AppleScript (where used) is pre-compiled, cached, and parameterised — no raw script strings in tool arguments.

## Build

Requires Swift 6+, macOS 13+, and the `Developer ID Application: Iosif Groberman (K8TEAW9B4H)` codesigning identity in your login keychain.

```bash
# Build & sign the .app
./scripts/build-app.sh                # → dist/MacMCP.app

# Pack the Claude Desktop Extension bundle
./scripts/pack-mcpb.sh                # → dist/mac-mcp.mcpb

# Quick MCP stdio smoke test
./scripts/smoke-test.sh
```

Override the signing identity with `MACMCP_SIGN_IDENTITY=...` if needed.

## Install

Either:

1. Double-click `dist/mac-mcp.mcpb`, or
2. Drag it into **Claude Desktop → Settings → Extensions**.

On first tool call you'll be prompted once for Accessibility and Automation grants. Because the binary is code-signed, those grants persist across rebuilds.

## Audit log

Every tool call appends a JSONL line to `~/Library/Logs/mac-mcp/audit.log`:

```json
{"ts":"2026-04-17T00:50:12.123Z","level":"info","msg":"tool ok","meta":{"tool":"list_windows","ms":"4"}}
```

Rotated at 10 MB. No network telemetry.

## Network policy

Zero outbound connections. `Info.plist` declares `NSAllowsArbitraryLoads=false` with no exception domains and an empty `NSPinnedDomains` policy.

## License

Proprietary (private repository).
