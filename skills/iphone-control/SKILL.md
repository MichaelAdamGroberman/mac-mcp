---
name: mac-mcp-iphone-control
description: Use when the user wants to drive their iPhone via macOS iPhone Mirroring — sending text, tapping UI elements, taking screenshots of the phone, or running multi-step phone workflows. Encodes the right tool sequence (launch → focus → act) and the iPhone-Mirroring-specific quirks like coordinate translation for taps.
---

# Driving an iPhone via mac-mcp's iphone_mirror tool

iPhone Mirroring (`com.apple.ScreenContinuity`, macOS Sonoma+) only works when:
- Both Mac and iPhone are signed into the same Apple ID
- The iPhone is unlocked or nearby
- The iPhone is on the same Wi-Fi network or close enough for AirPlay

If any of those aren't true, `iphone_mirror launch` returns successfully but the window will show a "Cannot connect" message. There's no programmatic way to detect that — ask the user to confirm visually.

## Standard workflow

For *any* iPhone interaction, always:

1. **`iphone_mirror action=launch`** — idempotent; returns `already_running:true` if already up.
2. **Wait briefly** (the model should not call back-to-back; insert a small `await` if your runtime supports it — otherwise just trust the user/runtime).
3. **`iphone_mirror action=focus`** — brings the window to front.
4. Then act.

## Sending text into a focused field

```
iphone_mirror action=type_text text="hello world" delay_ms=12
```

The default 8 ms inter-keystroke delay works for iMessage and most iOS text fields. If text drops characters, raise `delay_ms` to 25–40.

## Tapping a UI element on the phone screen

The `iphone_mirror` tool intentionally does NOT include `tap`. Use `mouse_click` against the mirrored window's bounds:

1. `iphone_mirror action=get_window` → returns `bounds: {x, y, width, height}`
2. Compute screen coords from the iPhone-relative tap point. iPhone Mirroring renders the phone at native resolution scaled to fit; for a tap at iPhone-coord `(ix, iy)` on a phone of native size `(IW, IH)` and window bounds `(wx, wy, ww, wh)`:
   ```
   sx = wx + (ix / IW) * ww
   sy = wy + (iy / IH) * wh
   ```
3. `mouse_click x=<sx> y=<sy>`

If you only know the *visual* location ("tap the blue button mid-screen"), call `iphone_mirror action=screenshot` first, identify the location in the returned PNG, and translate from PNG coords → window coords (they're the same in this case since the screenshot is OF the window).

## Capturing the iPhone screen

```
iphone_mirror action=screenshot
```

Returns a base64 PNG. If the call returns `capture_failed`, the user hasn't granted Screen Recording to MacMCP — invoke the `mac-mcp-tcc-grant` skill.

## Don't

- Don't try to bypass the launch step "to save a turn" — iPhone Mirroring re-attaches to the phone state on every launch and the first call without a focused window will fail silently.
- Don't `mouse_drag` for swipe gestures on the iPhone — Sonoma's iPhone Mirroring doesn't translate them. Use `mouse_scroll` instead, or send the equivalent keyboard shortcut if one exists.
