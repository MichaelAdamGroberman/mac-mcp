---
name: mac-mcp-tcc-grant
description: Use when a mac-mcp tool returns tcc_accessibility_denied, tcc_full_disk_access_denied, or any TCC/permission error. Walks the user through granting macOS permissions to MacMCP.app and verifying the grant persists. Especially useful first-time after installing the .mcpb.
---

# Granting macOS permissions to mac-mcp

A mac-mcp tool just returned a TCC error. Don't retry the same call — it will fail the same way until the user grants the permission in System Settings.

## Steps

1. **Identify which permission is needed** from the error code:

   | Error code | Permission to grant |
   |---|---|
   | `tcc_accessibility_denied` | Accessibility |
   | `tcc_full_disk_access_denied` | Full Disk Access (only for `messages action=list_recent`) |
   | (Apple Events failures from `mail`/`calendar`/`messages`/`safari`/`notes`/`terminal`/`iphone_mirror`) | Automation → toggle on the target app under MacMCP |
   | `capture_failed` for `screenshot_window` of another app | Screen Recording |

2. **Tell the user the exact pane** to open:

   ```
   System Settings → Privacy & Security → <Permission name>
   ```

   Then add or enable **MacMCP**. They may need to click the lock and authenticate.

3. **Verify persistence** by asking them to fully quit and re-open Claude Desktop, then call the same tool again. Because MacMCP is code-signed with a stable Developer ID identity (`Authority=Developer ID Application: Iosif Groberman (K8TEAW9B4H)`), the grant survives rebuilds — they should not be re-prompted.

4. **If still failing after grant**: call `list_apps` and verify `MacMCP` (or `com.michaelgroberman.MacMCP`) is *not* in the list (it shouldn't be — it's `LSUIElement`). Then check `~/Library/Logs/mac-mcp/audit.log` (use `fs_read`) for clues. The most common false-failure is the user toggling the wrong row in System Settings.

## What NOT to do

- Don't suggest `tccutil reset Accessibility` — that nukes ALL apps' Accessibility grants, not just MacMCP's.
- Don't suggest re-installing the `.mcpb` to "reset permissions" — that doesn't help and re-installs the same identity.
- Don't suggest disabling SIP. Ever.
