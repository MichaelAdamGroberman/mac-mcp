---
name: mac-mcp-window-arrange
description: Use when the user wants to manipulate window layout — focus an app, tile windows side-by-side, send a window to a specific space, maximize, or restore a previous arrangement. Encodes the right tool sequence (list → match → move/resize) and the macOS-specific gotchas around AX windows vs CGWindowID.
---

# Window arrangement with mac-mcp

Window IDs are CGWindowIDs from `list_windows`. The Accessibility API uses its own AX handles, but mac-mcp's `move_window` / `resize_window` / `focus_window` accept CGWindowIDs directly and translate internally.

## Common patterns

### "Focus app X" / "switch to app X"
```
focus_app bundle_id=<X>     # preferred — exact
# or
focus_app name=<X>          # fallback — localized name
```

If the app isn't running, `focus_app` will *launch* it (when bundle_id is provided). It returns `launched:true` so you can tell the user.

### "Tile two windows side by side"
```
list_windows                                 # find the two ids
# Get screen size from screenshot_screen.width/height of display 0 OR
# from the existing window bounds + extrapolation.
move_window window_id=<A> x=0 y=0
resize_window window_id=<A> width=<W/2> height=<H>
move_window window_id=<B> x=<W/2> y=0
resize_window window_id=<B> width=<W/2> height=<H>
```

Caveat: macOS menu bar takes ~30 px at the top, dock takes 80 px at the bottom (when visible). For "true" usable area, query a specific display via `screenshot_screen` and use that width/height as bounds.

### "Maximize this window" / "make it fullscreen"
mac-mcp does not yet have a `fullscreen_window` tool (real fullscreen creates a new Space). For "maximize without fullscreen":
```
move_window window_id=<id> x=0 y=0
resize_window window_id=<id> width=<display_width> height=<display_height>
```

### "Switch to space N"
```
set_space index=<N>
```

This synthesises Ctrl+N (the system shortcut for "Switch to Desktop N"). It only works if the user has those shortcuts enabled in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. If the user reports nothing happened, that's likely why.

## Gotchas

- **Multiple windows of the same app**: `list_windows` returns one entry per window with the same `owner`. Match by `title` to disambiguate, not by `pid`.
- **Hidden windows**: pass `on_screen_only=false` to `list_windows` to include minimized/hidden ones.
- **Floating panels**: high `layer` values (>= 25) are usually system overlays (notifications, menu bar). Filter them out unless the user asks about them specifically.
- **Permission**: `move_window` / `resize_window` / `focus_window` require Accessibility. If they error with `tcc_accessibility_denied`, invoke the `mac-mcp-tcc-grant` skill.
