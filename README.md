# mac-mcp

[![release](https://img.shields.io/github/v/release/MichaelAdamGroberman/mac-mcp?display_name=tag&sort=semver)](https://github.com/MichaelAdamGroberman/mac-mcp/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://github.com/MichaelAdamGroberman/mac-mcp)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![signed](https://img.shields.io/badge/signed-Developer%20ID%20%2B%20hardened%20runtime-success)](https://github.com/MichaelAdamGroberman/mac-mcp/blob/main/SECURITY.md)
[![mcpb](https://img.shields.io/badge/format-.mcpb-purple)](https://www.anthropic.com/engineering/desktop-extensions)
[![tools](https://img.shields.io/badge/tools-32-informational)](https://github.com/MichaelAdamGroberman/mac-mcp#tools-32)

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

### Notarization (for distribution outside this Mac)

For local installs the codesigned `.mcpb` works as-is. To distribute the bundle to other machines without Gatekeeper warnings, notarize and staple it.

One-time setup — store credentials in the login keychain:

```bash
xcrun notarytool store-credentials macmcp-notary \
    --apple-id "you@example.com" \
    --team-id  "K8TEAW9B4H" \
    --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
```

Generate the app-specific password at https://appleid.apple.com → *Sign-In and Security* → *App-Specific Passwords*.

Then:

```bash
./scripts/build-app.sh    # sign
./scripts/notarize.sh     # submit, wait, staple, repack dist/mac-mcp.mcpb
```

Verify:

```bash
spctl -a -vv -t install dist/MacMCP.app
# accepted source=Notarized Developer ID
```

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

MIT — see [LICENSE](LICENSE).

## Maintainer

Maintained by **Michael Adam Groberman**.

- **GitHub:** [@MichaelAdamGroberman](https://github.com/MichaelAdamGroberman)
- **LinkedIn:** [michael-adam-groberman](https://www.linkedin.com/in/michael-adam-groberman/)

For security reports use GitHub private vulnerability advisories (see [SECURITY.md](SECURITY.md)) — **do not** use LinkedIn DMs for sensitive disclosures.
