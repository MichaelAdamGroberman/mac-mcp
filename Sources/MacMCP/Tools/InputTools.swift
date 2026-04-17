import Foundation
import AppKit
import CoreGraphics
import MCP

enum InputTools {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "mouse_move",
            description: "Move the mouse cursor to (x, y) in global screen coordinates.",
            inputSchema: Schema.object(properties: [
                "x": Schema.int("X in points (0,0 is top-left of main display)."),
                "y": Schema.int("Y in points.")
            ], required: ["x", "y"])
        ) { args in
            try Permissions.requireAccessibility()
            guard let x = args.int("x"), let y = args.int("y") else {
                throw MacMCPError(code: "missing_arg", message: "x, y required")
            }
            let pt = clampToDisplays(CGPoint(x: x, y: y))
            try post(event: CGEvent(mouseEventSource: source(), mouseType: .mouseMoved,
                                    mouseCursorPosition: pt, mouseButton: .left))
            return jsonResult(.object(["moved_to": .object(["x": .int(Int(pt.x)), "y": .int(Int(pt.y))])]))
        }

        r.add(
            name: "mouse_click",
            description: "Click at (x, y). Button: left|right|middle (default left). count: 1=single, 2=double, 3=triple.",
            inputSchema: Schema.object(properties: [
                "x": Schema.int("X in points (omit to click at current cursor)."),
                "y": Schema.int("Y in points (omit to click at current cursor)."),
                "button": Schema.string("Mouse button.", enumValues: ["left", "right", "middle"]),
                "count": Schema.int("Click count 1..3 (default 1)."),
                "modifiers": Schema.array(
                    items: Schema.string("Modifier", enumValues: ["cmd", "shift", "option", "control", "fn"]),
                    description: "Modifier keys to hold during the click."
                )
            ])
        ) { args in
            try Permissions.requireAccessibility()
            let button = args.string("button") ?? "left"
            let count = max(1, min(args.int("count") ?? 1, 3))
            let mods = parseModifiers(args["modifiers"])

            let pt: CGPoint
            if let x = args.int("x"), let y = args.int("y") {
                pt = clampToDisplays(CGPoint(x: x, y: y))
            } else {
                pt = NSEvent.mouseLocation.flippedToCG()
            }

            let (downType, upType, mb): (CGEventType, CGEventType, CGMouseButton) = {
                switch button {
                case "right":  return (.rightMouseDown, .rightMouseUp, .right)
                case "middle": return (.otherMouseDown, .otherMouseUp, .center)
                default:       return (.leftMouseDown, .leftMouseUp, .left)
                }
            }()

            for i in 1...count {
                let down = CGEvent(mouseEventSource: source(), mouseType: downType,
                                   mouseCursorPosition: pt, mouseButton: mb)
                let up   = CGEvent(mouseEventSource: source(), mouseType: upType,
                                   mouseCursorPosition: pt, mouseButton: mb)
                down?.flags = mods
                up?.flags = mods
                down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                try post(event: down)
                try post(event: up)
                if i < count { try await Task.sleep(nanoseconds: 30_000_000) }
            }
            return jsonResult(.object([
                "clicked": .object(["x": .int(Int(pt.x)), "y": .int(Int(pt.y))]),
                "button": .string(button),
                "count": .int(count)
            ]))
        }

        r.add(
            name: "mouse_drag",
            description: "Press at (from_x, from_y), drag to (to_x, to_y), release. Capped at 4096 px per axis.",
            inputSchema: Schema.object(properties: [
                "from_x": Schema.int("Start X."),
                "from_y": Schema.int("Start Y."),
                "to_x": Schema.int("End X."),
                "to_y": Schema.int("End Y."),
                "button": Schema.string("Mouse button.", enumValues: ["left", "right", "middle"]),
                "duration_ms": Schema.int("How long the drag should take (default 200ms, max 5000).")
            ], required: ["from_x", "from_y", "to_x", "to_y"])
        ) { args in
            try Permissions.requireAccessibility()
            guard let fx = args.int("from_x"), let fy = args.int("from_y"),
                  let tx = args.int("to_x"), let ty = args.int("to_y") else {
                throw MacMCPError(code: "missing_arg", message: "from/to coordinates required")
            }
            let dx = abs(tx - fx), dy = abs(ty - fy)
            if dx > 4096 || dy > 4096 {
                throw MacMCPError(code: "drag_too_far", message: "drag distance capped at 4096 px per axis")
            }
            let durationMs = max(0, min(args.int("duration_ms") ?? 200, 5000))
            let button = args.string("button") ?? "left"
            let (downType, upType, dragType, mb): (CGEventType, CGEventType, CGEventType, CGMouseButton) = {
                switch button {
                case "right":  return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
                case "middle": return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
                default:       return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
                }
            }()

            let from = clampToDisplays(CGPoint(x: fx, y: fy))
            let to = clampToDisplays(CGPoint(x: tx, y: ty))
            let steps = max(2, min(60, durationMs / 16))
            try post(event: CGEvent(mouseEventSource: source(), mouseType: downType,
                                    mouseCursorPosition: from, mouseButton: mb))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let pt = CGPoint(x: from.x + (to.x - from.x) * t,
                                 y: from.y + (to.y - from.y) * t)
                try post(event: CGEvent(mouseEventSource: source(), mouseType: dragType,
                                        mouseCursorPosition: pt, mouseButton: mb))
                if durationMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000 / UInt64(steps))
                }
            }
            try post(event: CGEvent(mouseEventSource: source(), mouseType: upType,
                                    mouseCursorPosition: to, mouseButton: mb))
            return jsonResult(.object(["dragged": .bool(true)]))
        }

        r.add(
            name: "mouse_scroll",
            description: "Send a scroll-wheel event. Positive dy = scroll up; positive dx = scroll right.",
            inputSchema: Schema.object(properties: [
                "dx": Schema.int("Horizontal scroll units (default 0)."),
                "dy": Schema.int("Vertical scroll units."),
                "smooth": Schema.bool("Use pixel (smooth) units instead of line units (default false).")
            ])
        ) { args in
            try Permissions.requireAccessibility()
            let dx = Int32(args.int("dx") ?? 0)
            let dy = Int32(args.int("dy") ?? 0)
            let smooth = args.bool("smooth") ?? false
            guard let ev = CGEvent(
                scrollWheelEvent2Source: source(),
                units: smooth ? .pixel : .line,
                wheelCount: 2,
                wheel1: dy,
                wheel2: dx,
                wheel3: 0
            ) else {
                throw MacMCPError(code: "cgevent_failed", message: "Could not create scroll event")
            }
            ev.post(tap: .cghidEventTap)
            return jsonResult(.object(["scrolled": .object(["dx": .int(Int(dx)), "dy": .int(Int(dy))])]))
        }

        r.add(
            name: "key_press",
            description: "Press a single key (or chord) once. key may be a literal char ('a','1') or named key ('return','escape','tab','space','delete','arrow_left','arrow_right','arrow_up','arrow_down','f1'..'f12').",
            inputSchema: Schema.object(properties: [
                "key": Schema.string("Key name or single character."),
                "modifiers": Schema.array(
                    items: Schema.string("Modifier", enumValues: ["cmd", "shift", "option", "control", "fn"]),
                    description: "Modifier keys to hold."
                )
            ], required: ["key"])
        ) { args in
            try Permissions.requireAccessibility()
            let key = try args.requiredString("key")
            let mods = parseModifiers(args["modifiers"])
            guard let kc = keyCode(for: key) else {
                throw MacMCPError(code: "unknown_key", message: "No key code mapping for '\(key)'")
            }
            try post(keyCode: kc, flags: mods, keyDown: true)
            try post(keyCode: kc, flags: mods, keyDown: false)
            return jsonResult(.object(["pressed": .string(key)]))
        }

        r.add(
            name: "type_text",
            description: "Type a Unicode string by posting key events with full UTF-16 support. Capped at 10,000 chars.",
            inputSchema: Schema.object(properties: [
                "text": Schema.string("Text to type."),
                "delay_ms": Schema.int("Inter-keystroke delay (default 5ms, max 200).")
            ], required: ["text"])
        ) { args in
            try Permissions.requireAccessibility()
            let text = try args.requiredString("text")
            if text.count > 10_000 {
                throw MacMCPError(code: "text_too_long", message: "type_text capped at 10,000 chars (got \(text.count))")
            }
            let delayMs = max(0, min(args.int("delay_ms") ?? 5, 200))
            for unichar in text.utf16 {
                try postUnicodeChar(unichar)
                if delayMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
            return jsonResult(.object(["typed": .int(text.count)]))
        }
    }

    // MARK: - helpers

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private static func post(event: CGEvent?) throws {
        guard let event else {
            throw MacMCPError(code: "cgevent_failed", message: "CGEvent allocation failed")
        }
        event.post(tap: .cghidEventTap)
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) throws {
        guard let ev = CGEvent(keyboardEventSource: source(), virtualKey: keyCode, keyDown: keyDown) else {
            throw MacMCPError(code: "cgevent_failed", message: "key event allocation failed")
        }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    private static func postUnicodeChar(_ ch: UTF16.CodeUnit) throws {
        guard let down = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: false) else {
            throw MacMCPError(code: "cgevent_failed", message: "unicode key event allocation failed")
        }
        var c = ch
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func parseModifiers(_ v: Value?) -> CGEventFlags {
        var f: CGEventFlags = []
        guard case .array(let arr) = v else { return f }
        for item in arr {
            switch item.stringValue {
            case "cmd":     f.insert(.maskCommand)
            case "shift":   f.insert(.maskShift)
            case "option":  f.insert(.maskAlternate)
            case "control": f.insert(.maskControl)
            case "fn":      f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    private static func clampToDisplays(_ p: CGPoint) -> CGPoint {
        // Union of all active displays; clamp to bounding rect to avoid invalid posts.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        var bounds = CGRect.null
        for i in 0..<Int(count) {
            bounds = bounds.union(CGDisplayBounds(ids[i]))
        }
        if bounds.isNull || bounds.isEmpty { return p }
        return CGPoint(x: max(bounds.minX, min(p.x, bounds.maxX - 1)),
                       y: max(bounds.minY, min(p.y, bounds.maxY - 1)))
    }

    private static func keyCode(for name: String) -> CGKeyCode? {
        if let k = namedKeys[name.lowercased()] { return k }
        if name.count == 1, let c = name.unicodeScalars.first {
            return ansiKeyCode(for: Character(c))
        }
        return nil
    }

    private static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forward_delete": 117, "home": 115, "end": 119,
        "page_up": 116, "page_down": 121,
        "arrow_left": 123, "arrow_right": 124, "arrow_down": 125, "arrow_up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    private static func ansiKeyCode(for c: Character) -> CGKeyCode? {
        // ANSI US layout map for the common printables; non-printables go through
        // the unicode-string path in type_text instead.
        let map: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "`": 50
        ]
        return map[Character(String(c).lowercased())]
    }
}

private extension NSPoint {
    /// Convert from AppKit coords (origin bottom-left of main display) to CG (top-left).
    func flippedToCG() -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: h - y)
    }
}
