# Contributing

This is a private repository. External contributions are not currently accepted.

If you have access:

1. Branch from `main`.
2. Run `swift test` and `./scripts/smoke-test.sh` before opening a PR.
3. New tools must:
   - Have an explicit JSON schema with bounded inputs (no unbounded strings passed to AppleScript / `Process`).
   - Use native Cocoa / Accessibility / OSAKit APIs in preference to shelling out.
   - Add an entry to `manifest.json` and the README tool list.
   - Add a unit test in `Tests/MacMCPCoreTests/` for any logic that doesn't require TCC.
4. No `run_shell`, `run_applescript`, or `eval_*` tools — see SECURITY.md.

## Style

- Swift API design guidelines.
- 4-space indent.
- One tool bucket per file under `Sources/MacMCP/Tools/`.
