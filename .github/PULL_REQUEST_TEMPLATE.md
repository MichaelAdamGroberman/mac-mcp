## Summary

- What this changes and why.

## Tools touched / added

- [ ] Lists the new/changed tools and their schemas.

## Checklist

- [ ] No `run_shell` / `run_applescript` / `eval_*` introduced.
- [ ] All AppleScript is pre-compiled & parameterised (no raw script in tool args).
- [ ] Hard limits set on inputs (timeouts, result-size caps).
- [ ] `manifest.json` updated if a tool was added/renamed/removed.
- [ ] README tool list updated.
- [ ] `swift test` and `scripts/smoke-test.sh` pass locally.
- [ ] Codesigning still succeeds (`scripts/build-app.sh`).

## Risk

- TCC permission impact (new prompt? new scripting target?):
- Breaking change to existing tool surface? (yes/no)
