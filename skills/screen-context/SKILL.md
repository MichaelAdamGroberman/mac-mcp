---
name: mac-mcp-screen-context
description: Use when the user asks "what's on my screen?", "what am I looking at?", "describe this app/window/file", or wants you to act on the *visual* state of macOS. Picks the right capture tool (display vs window vs iPhone), keeps PNG sizes manageable, and translates results for vision-capable models.
---

# Reading the user's macOS screen state

Three capture surfaces, each with its own tool. Pick deliberately — don't always grab the whole display:

| Source | Tool | When to use |
|---|---|---|
| Whole display | `screenshot_screen` (optional `display_index`) | "What's on my screen?", multi-app overview, when no specific app named |
| Specific window | `screenshot_window` (needs `window_id`) | User names an app or asks about one app; smaller payload, more focused |
| iPhone | `iphone_mirror action=screenshot` | User mentions iPhone, iOS app, phone notification, etc. |

## The right sequence for "describe what app X is showing"

1. `list_windows` → find the entry where `owner` matches app name X (case-insensitive `localizedCaseInsensitiveContains` is fine)
2. `screenshot_window window_id=<id from step 1>`
3. Pass the returned `image_png_b64` to vision (your runtime handles this — don't stringify it back at the user)

This is dramatically smaller and faster than `screenshot_screen` + cropping, and avoids capturing other apps' contents (privacy + token cost).

## Display selection for multi-monitor setups

If `screenshot_screen` is called without `display_index` it captures display 0 (main). Users with multi-monitor setups often mean "the screen I'm looking at" which is *not* always the main. Heuristic:
- If the user just mentioned a window/app, get its bounds via `list_windows` and pick the display whose `CGDisplayBounds` contains those bounds.
- Otherwise default to 0 and surface the assumption: "Captured your main display (Display 0)…"

## Don't

- Don't OCR the screenshot yourself by hand. Pass it to vision.
- Don't capture if Screen Recording isn't granted — `screenshot_screen` returns `capture_failed`. Invoke `mac-mcp-tcc-grant` first.
- Don't include the base64 string in your *visible* response to the user (it's huge). Only refer to its contents.
