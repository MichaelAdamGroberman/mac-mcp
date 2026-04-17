import Foundation
import AppKit
import CoreGraphics
import MCP

enum iPhoneMirrorTool {
    /// Bundle id of macOS Sonoma+'s iPhone Mirroring app.
    private static let bundleId = "com.apple.ScreenContinuity"

    static func register(into r: ToolRegistry) {
        r.add(
            name: "iphone_mirror",
            description: "Control the macOS iPhone Mirroring app (Sonoma+): launch, focus, type_text, screenshot. Tapping is done with mouse_click on the mirrored window's coordinates.",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which iphone_mirror action.",
                    enumValues: ["launch", "focus", "type_text", "screenshot", "get_window"]),
                "text": Schema.string("Text to type into the focused mirror window (type_text)."),
                "delay_ms": Schema.int("Inter-keystroke delay (type_text, default 8ms, max 200).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "launch":
                return try await launchMirror()
            case "focus":
                return try focusMirror()
            case "get_window":
                return try getMirrorWindow()
            case "type_text":
                return try await typeIntoMirror(
                    text: try args.requiredString("text"),
                    delayMs: max(0, min(args.int("delay_ms") ?? 8, 200))
                )
            case "screenshot":
                return try screenshotMirror()
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown iphone_mirror action: \(action)")
            }
        }
    }

    private static func launchMirror() async throws -> CallTool.Result {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first != nil {
            try focusMirror()
            return jsonResult(.object(["launched": .bool(false), "already_running": .bool(true)]))
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw MacMCPError(code: "not_found",
                              message: "iPhone Mirroring not installed (requires macOS Sonoma+ and a paired iPhone).")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NSRunningApplication?, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: app) }
            }
        }
        return jsonResult(.object(["launched": .bool(true)]))
    }

    private static func focusMirror() throws -> CallTool.Result {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw MacMCPError(code: "not_running", message: "iPhone Mirroring is not running. Call action=launch first.")
        }
        app.activate(options: [.activateAllWindows])
        return jsonResult(.object(["focused": .bool(true), "pid": .int(Int(app.processIdentifier))]))
    }

    private static func getMirrorWindow() throws -> CallTool.Result {
        guard let info = mirrorWindowInfo() else {
            throw MacMCPError(code: "no_window",
                              message: "No iPhone Mirroring window found. Launch it and ensure your iPhone is connected.")
        }
        return jsonResult(.object(info))
    }

    private static func typeIntoMirror(text: String, delayMs: Int) async throws -> CallTool.Result {
        try Permissions.requireAccessibility()
        try focusMirror()
        try await Task.sleep(nanoseconds: 150_000_000) // give focus time to settle
        for ch in text.utf16 {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw MacMCPError(code: "cgevent_failed", message: "key event allocation failed")
            }
            var c = ch
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if delayMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }
        return jsonResult(.object(["typed": .int(text.count)]))
    }

    private static func screenshotMirror() throws -> CallTool.Result {
        guard let info = mirrorWindowInfo(), let id = info["id"]?.intValue else {
            throw MacMCPError(code: "no_window", message: "No iPhone Mirroring window to capture.")
        }
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(id),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw MacMCPError(code: "capture_failed",
                              message: "Could not capture iPhone Mirroring window — Screen Recording permission may be required.")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MacMCPError(code: "encode_failed", message: "PNG encoding failed")
        }
        return jsonResult(.object([
            "width": .int(cgImage.width),
            "height": .int(cgImage.height),
            "image_png_b64": .string(png.base64EncodedString())
        ]))
    }

    private static func mirrorWindowInfo() -> [String: Value]? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for w in raw {
            guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            // The app is named "iPhone Mirroring" in the user-visible UI.
            if owner.localizedCaseInsensitiveContains("iphone mirror") || owner == "ScreenContinuity" {
                let id = (w[kCGWindowNumber as String] as? Int) ?? -1
                let bounds = (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
                return [
                    "id": .int(id),
                    "owner": .string(owner),
                    "title": .string((w[kCGWindowName as String] as? String) ?? ""),
                    "bounds": .object([
                        "x": .double(Double(bounds["X"] ?? 0)),
                        "y": .double(Double(bounds["Y"] ?? 0)),
                        "width": .double(Double(bounds["Width"] ?? 0)),
                        "height": .double(Double(bounds["Height"] ?? 0))
                    ])
                ]
            }
        }
        return nil
    }
}
