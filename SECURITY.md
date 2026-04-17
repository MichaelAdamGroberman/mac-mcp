# Security Policy

## Reporting a vulnerability

This is a private repository. To report a security issue in `mac-mcp`, email **michael.groberman@icloud.com** with the subject prefix `[mac-mcp security]`. PGP keys available on request.

Please do not open public GitHub issues for security findings.

## Threat model

`mac-mcp` is a local MCP server that runs as the logged-in user, with the same TCC grants the user has explicitly given it. It exposes a typed, allow-listed tool surface to a connected MCP client (Claude Desktop). Concretely:

- **Trust boundary**: the MCP client (Claude Desktop) is trusted to send valid tool calls. The server validates all schemas and enforces hard limits (timeouts, result-size caps).
- **No remote attack surface**: the server speaks **stdio only**. It opens no listening sockets and makes no outbound network calls. `NSAppTransportSecurity` declares `NSAllowsArbitraryLoads=false` and an empty `NSPinnedDomains` policy.
- **TCC**: every privileged capability (Accessibility, Apple Events, Full Disk Access for Messages history) requires an explicit user grant, prompted by macOS, scoped to the signed `MacMCP.app` bundle identity.
- **No escape hatch**: there is no `run_shell`, `run_applescript`, or `eval_python` tool. AppleScript used for app-specific automation is **pre-compiled and parameterised**; tool arguments are never interpolated as raw script bodies.
- **Audit log**: every tool call (including failures and unknown-tool requests) is recorded in `~/Library/Logs/mac-mcp/audit.log` (JSONL, rotated at 10 MB). No network telemetry.

## Out of scope

- Privilege escalation in macOS itself, third-party apps targeted via Apple Events, or the MCP transport (these are upstream concerns).
- Side-channel attacks against pasteboard, screenshot, or clipboard contents — these are user-controlled disclosures.

## Hardening checklist (release)

- [ ] Built with `--options runtime` (hardened runtime) and a `Developer ID Application` signature
- [ ] Notarised before public distribution (currently private; n/a)
- [ ] `NSAppTransportSecurity` denies all networking
- [ ] No tool accepts an unbounded string that is later passed to `osascript -e`, `Process`, or `NSTask` without explicit allow-listing
- [ ] Audit log enabled at `info` or below
