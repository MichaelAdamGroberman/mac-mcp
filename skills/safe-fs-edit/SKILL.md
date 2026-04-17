---
name: mac-mcp-safe-fs-edit
description: Use BEFORE any fs_write with mode='overwrite' or mode='append' on a file that already exists, especially user documents, source code, dotfiles, or anything not under version control. Snapshots the original to a timestamped path so the change is reversible without relying on the user's Time Machine.
---

# Safe overwrite for mac-mcp filesystem edits

`fs_write` with `mode='overwrite'` is destructive — it replaces the file's contents in one atomic operation with no undo. `fs_delete` defaults to Trash so it's recoverable; `fs_write` does not. This skill adds a recovery layer.

## Workflow

Before calling `fs_write` on an existing file:

1. **Stat the target** to confirm it exists and is reasonable size:
   ```
   fs_stat path=<target>
   ```
   If `kind != "file"` or `size > 50_000_000`, abort and ask the user.

2. **Snapshot it** to a timestamped path under `~/.mac-mcp/snapshots/`:
   ```
   fs_make_dir path="~/.mac-mcp/snapshots/<YYYY-MM-DD-HHMMSS>" parents=true
   fs_copy src=<target> dst="~/.mac-mcp/snapshots/<ts>/<basename>"
   ```

3. **Then perform the write**:
   ```
   fs_write path=<target> mode="overwrite" text=<new content>
   ```

4. **Tell the user** in the response message what you snapshotted and where, so they can `fs_copy` it back if needed:
   > Saved snapshot at `~/.mac-mcp/snapshots/2026-04-17-014203/foo.swift` before overwriting.

## When to skip

- The file is in a git working tree and `git diff` would show the change (the user has version control)
- `mode='create'` (file doesn't exist yet — nothing to lose)
- The user explicitly says "don't snapshot, just write"

## Cleanup

Don't auto-delete snapshots — the user does that. If they ask "clean up mac-mcp snapshots", call `fs_delete path="~/.mac-mcp/snapshots/<old>"` (trash, not permanent).
