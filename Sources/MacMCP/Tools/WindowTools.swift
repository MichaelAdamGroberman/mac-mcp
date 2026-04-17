import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import MCP

enum WindowTools {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "list_apps",
            description: "List running applications (bundle id, name, pid, frontmost).",
            inputSchema: Schema.object(properties: [:])
        ) { _ in
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { app -> [String: Value] in
                    [
                        "pid": .int(Int(app.processIdentifier)),
                        "bundle_id": .string(app.bundleIdentifier ?? ""),
                        "name": .string(app.localizedName ?? ""),
                        "frontmost": .bool(app.isActive)
                    ]
                }
            return jsonResult(.array(apps.map { .object($0) }))
        }

        r.add(
            name: "list_windows",
            description: "List on-screen windows with id, title, owner, pid, bounds, layer.",
            inputSchema: Schema.object(properties: [
                "on_screen_only": Schema.bool("Only windows currently on screen (default true).")
            ])
        ) { args in
            let onScreenOnly = args.bool("on_screen_only") ?? true
            let opts: CGWindowListOption = onScreenOnly
                ? [.optionOnScreenOnly, .excludeDesktopElements]
                : [.optionAll, .excludeDesktopElements]
            guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
                return jsonResult(.array([]))
            }
            let windows: [Value] = raw.compactMap { w in
                guard let id = w[kCGWindowNumber as String] as? Int,
                      let owner = w[kCGWindowOwnerName as String] as? String,
                      let pid = w[kCGWindowOwnerPID as String] as? Int else { return nil }
                let title = (w[kCGWindowName as String] as? String) ?? ""
                let bounds = (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
                let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
                return .object([
                    "id": .int(id),
                    "title": .string(title),
                    "owner": .string(owner),
                    "pid": .int(pid),
                    "layer": .int(layer),
                    "bounds": .object([
                        "x": .double(Double(bounds["X"] ?? 0)),
                        "y": .double(Double(bounds["Y"] ?? 0)),
                        "width": .double(Double(bounds["Width"] ?? 0)),
                        "height": .double(Double(bounds["Height"] ?? 0))
                    ])
                ])
            }
            return jsonResult(.array(windows))
        }

        r.add(
            name: "focus_app",
            description: "Activate an application by bundle id or name.",
            inputSchema: Schema.object(properties: [
                "bundle_id": Schema.string("Bundle id (preferred), e.g. com.apple.Safari."),
                "name": Schema.string("Localized application name (fallback if bundle id missing).")
            ])
        ) { args in
            let bundleId = args.string("bundle_id")
            let name = args.string("name")
            let app: NSRunningApplication? = {
                if let bundleId, !bundleId.isEmpty {
                    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
                }
                if let name, !name.isEmpty {
                    return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
                }
                return nil
            }()
            guard let app else {
                if let bundleId, !bundleId.isEmpty,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    let launched: NSRunningApplication? = try await withCheckedThrowingContinuation { cont in
                        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { running, error in
                            if let error {
                                cont.resume(throwing: error)
                            } else {
                                cont.resume(returning: running)
                            }
                        }
                    }
                    guard launched != nil else {
                        throw MacMCPError(code: "launch_failed", message: "Could not launch \(bundleId)")
                    }
                    return jsonResult(.object(["activated": .bool(true), "launched": .bool(true)]))
                }
                throw MacMCPError(code: "not_found", message: "App not running and could not be located")
            }
            app.activate(options: [.activateAllWindows])
            return jsonResult(.object([
                "activated": .bool(true),
                "pid": .int(Int(app.processIdentifier))
            ]))
        }

        r.add(
            name: "focus_window",
            description: "Raise and focus a specific window by its CGWindowID.",
            inputSchema: Schema.object(properties: [
                "window_id": Schema.int("CGWindowID from list_windows.")
            ], required: ["window_id"])
        ) { args in
            try Permissions.requireAccessibility()
            guard let id = args.int("window_id") else {
                throw MacMCPError(code: "missing_arg", message: "window_id required")
            }
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
                  let entry = info.first,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else {
                throw MacMCPError(code: "not_found", message: "Window \(id) not found")
            }
            let axApp = AXUIElementCreateApplication(pid)
            var winsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
            let wins = (winsRef as? [AXUIElement]) ?? []
            for w in wins {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
            }
            return jsonResult(.object(["focused": .bool(true)]))
        }

        r.add(
            name: "move_window",
            description: "Move a window's top-left to (x, y) in screen coordinates.",
            inputSchema: Schema.object(properties: [
                "window_id": Schema.int("CGWindowID from list_windows."),
                "x": Schema.int("X in screen points."),
                "y": Schema.int("Y in screen points.")
            ], required: ["window_id", "x", "y"])
        ) { args in
            try Permissions.requireAccessibility()
            guard let id = args.int("window_id"),
                  let x = args.int("x"),
                  let y = args.int("y") else {
                throw MacMCPError(code: "missing_arg", message: "window_id, x, y required")
            }
            guard let ax = axWindow(forCGWindowID: CGWindowID(id)) else {
                throw MacMCPError(code: "not_found", message: "AX window \(id) not found")
            }
            var pos = CGPoint(x: x, y: y)
            let posValue = AXValueCreate(.cgPoint, &pos)!
            AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posValue)
            return jsonResult(.object(["moved": .bool(true)]))
        }

        r.add(
            name: "resize_window",
            description: "Resize a window to (width, height) via Accessibility API.",
            inputSchema: Schema.object(properties: [
                "window_id": Schema.int("CGWindowID from list_windows."),
                "width": Schema.int("Width in screen points."),
                "height": Schema.int("Height in screen points.")
            ], required: ["window_id", "width", "height"])
        ) { args in
            try Permissions.requireAccessibility()
            guard let id = args.int("window_id"),
                  let w = args.int("width"),
                  let h = args.int("height") else {
                throw MacMCPError(code: "missing_arg", message: "window_id, width, height required")
            }
            guard let ax = axWindow(forCGWindowID: CGWindowID(id)) else {
                throw MacMCPError(code: "not_found", message: "AX window \(id) not found")
            }
            var size = CGSize(width: w, height: h)
            let sizeValue = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeValue)
            return jsonResult(.object(["resized": .bool(true)]))
        }

        r.add(
            name: "set_space",
            description: "Switch to a Mission Control space by 1-based index. Uses key-equivalent fallback because public Spaces APIs are limited.",
            inputSchema: Schema.object(properties: [
                "index": Schema.int("1-based space index (matches the system shortcut Ctrl-N).")
            ], required: ["index"])
        ) { args in
            guard let idx = args.int("index"), idx >= 1, idx <= 16 else {
                throw MacMCPError(code: "bad_arg", message: "index must be 1..16")
            }
            // Synthesize Ctrl + number key (depends on user enabling these shortcuts).
            let keyCodes: [Int: CGKeyCode] = [
                1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28,
                9: 25, 10: 29, 11: 27, 12: 24, 13: 86, 14: 87, 15: 88, 16: 89
            ]
            guard let kc = keyCodes[idx] else {
                throw MacMCPError(code: "bad_arg", message: "no key code for index \(idx)")
            }
            try postKeyChord(keyCode: kc, flags: .maskControl)
            return jsonResult(.object([
                "switched": .bool(true),
                "note": .string("Requires 'Switch to Desktop N' shortcuts enabled in System Settings → Keyboard.")
            ]))
        }
    }

    // MARK: - helpers

    private static func axWindow(forCGWindowID id: CGWindowID) -> AXUIElement? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = info.first,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
        let wins = (winsRef as? [AXUIElement]) ?? []
        // Match by title + size as a heuristic — AX has no public CGWindowID lookup.
        let title = (entry[kCGWindowName as String] as? String) ?? ""
        for w in wins {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            if let s = t as? String, s == title, !title.isEmpty {
                return w
            }
        }
        return wins.first
    }

    private static func postKeyChord(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw MacMCPError(code: "cgevent_failed", message: "CGEventSource init failed")
        }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

func jsonResult(_ v: Value) -> CallTool.Result {
    let data = (try? JSONEncoder().encode(JSONAny(v))) ?? Data()
    let str = String(data: data, encoding: .utf8) ?? "null"
    return .init(content: [.text(text: str)], isError: false)
}

private struct JSONAny: Encodable {
    let v: Value
    init(_ v: Value) { self.v = v }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch v {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let arr): try c.encode(arr.map { JSONAny($0) })
        case .object(let obj): try c.encode(obj.mapValues { JSONAny($0) })
        case .data(_, let d): try c.encode(d.base64EncodedString())
        }
    }
}
