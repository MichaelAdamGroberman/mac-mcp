import Foundation
import AppKit
import CoreGraphics
import UserNotifications
import MCP

enum SystemTools {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "clipboard_read",
            description: "Read the system pasteboard. Returns whichever of {text, rtf, image_png_b64, file_urls} are present.",
            inputSchema: Schema.object(properties: [:])
        ) { _ in
            let pb = NSPasteboard.general
            var out: [String: Value] = [:]
            if let s = pb.string(forType: .string) {
                out["text"] = .string(s)
            }
            if let rtf = pb.data(forType: .rtf) {
                out["rtf_b64"] = .string(rtf.base64EncodedString())
            }
            if let img = NSImage(pasteboard: pb),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                out["image_png_b64"] = .string(png.base64EncodedString())
            }
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                out["file_urls"] = .array(urls.map { .string($0.absoluteString) })
            }
            out["change_count"] = .int(pb.changeCount)
            return jsonResult(.object(out))
        }

        r.add(
            name: "clipboard_write",
            description: "Write a typed value to the pasteboard. Provide exactly one of {text, image_png_b64, file_paths}.",
            inputSchema: Schema.object(properties: [
                "text": Schema.string("Plain text to copy."),
                "image_png_b64": Schema.string("Base64-encoded PNG image to copy."),
                "file_paths": Schema.array(items: Schema.string("Path"), description: "File paths to copy as file URLs.")
            ])
        ) { args in
            let pb = NSPasteboard.general
            pb.clearContents()
            var wrote: [String] = []
            if let t = args.string("text") {
                pb.setString(t, forType: .string)
                wrote.append("text")
            }
            if let b64 = args.string("image_png_b64"),
               let data = Data(base64Encoded: b64),
               let img = NSImage(data: data) {
                pb.writeObjects([img])
                wrote.append("image")
            }
            if case .array(let arr) = args["file_paths"] {
                let urls = arr.compactMap { $0.stringValue }
                    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) as NSURL }
                if !urls.isEmpty {
                    pb.writeObjects(urls)
                    wrote.append("file_urls")
                }
            }
            if wrote.isEmpty {
                throw MacMCPError(code: "missing_arg", message: "Provide one of: text, image_png_b64, file_paths")
            }
            return jsonResult(.object([
                "wrote": .array(wrote.map { .string($0) }),
                "change_count": .int(pb.changeCount)
            ]))
        }

        r.add(
            name: "notify",
            description: "Post a notification to Notification Center. User must have granted notifications to MacMCP.",
            inputSchema: Schema.object(properties: [
                "title": Schema.string("Notification title."),
                "body": Schema.string("Notification body text."),
                "subtitle": Schema.string("Optional subtitle.")
            ], required: ["title", "body"])
        ) { args in
            let title = try args.requiredString("title")
            let body = try args.requiredString("body")
            let subtitle = args.string("subtitle") ?? ""

            let center = UNUserNotificationCenter.current()
            // Best-effort permission request; ignore errors (we still try to deliver).
            _ = try? await center.requestAuthorization(options: [.alert, .sound])

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if !subtitle.isEmpty { content.subtitle = subtitle }
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(req)
            } catch {
                throw MacMCPError(code: "notify_failed", message: String(describing: error))
            }
            return jsonResult(.object(["delivered": .bool(true)]))
        }

        r.add(
            name: "prompt_user",
            description: "Show a native NSAlert with an input field; returns the user's response. BLOCKS until user responds.",
            inputSchema: Schema.object(properties: [
                "title": Schema.string("Dialog title."),
                "message": Schema.string("Body text."),
                "default_value": Schema.string("Pre-filled input value (optional)."),
                "ok_label": Schema.string("OK button label (default 'OK')."),
                "cancel_label": Schema.string("Cancel button label (default 'Cancel').")
            ], required: ["title", "message"])
        ) { args in
            let title = try args.requiredString("title")
            let message = try args.requiredString("message")
            let defaultValue = args.string("default_value") ?? ""
            let okLabel = args.string("ok_label") ?? "OK"
            let cancelLabel = args.string("cancel_label") ?? "Cancel"

            return await MainActor.run {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.addButton(withTitle: okLabel)
                alert.addButton(withTitle: cancelLabel)
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = defaultValue
                alert.accessoryView = field
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                let confirmed = (response == .alertFirstButtonReturn)
                return jsonResult(.object([
                    "confirmed": .bool(confirmed),
                    "value": .string(confirmed ? field.stringValue : "")
                ]))
            }
        }

        r.add(
            name: "screenshot_screen",
            description: "Capture a display as base64 PNG.",
            inputSchema: Schema.object(properties: [
                "display_index": Schema.int("0 = main display (default).")
            ])
        ) { args in
            let idx = args.int("display_index") ?? 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetActiveDisplayList(16, &ids, &count)
            guard idx >= 0, idx < Int(count) else {
                throw MacMCPError(code: "bad_arg", message: "display_index out of range (have \(count) displays)")
            }
            guard let cgImage = CGDisplayCreateImage(ids[idx]) else {
                throw MacMCPError(code: "capture_failed", message: "CGDisplayCreateImage returned nil")
            }
            return jsonResult(pngResult(from: cgImage))
        }

        r.add(
            name: "screenshot_window",
            description: "Capture a specific window by CGWindowID as base64 PNG.",
            inputSchema: Schema.object(properties: [
                "window_id": Schema.int("CGWindowID from list_windows.")
            ], required: ["window_id"])
        ) { args in
            guard let id = args.int("window_id") else {
                throw MacMCPError(code: "missing_arg", message: "window_id required")
            }
            guard let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(id),
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                throw MacMCPError(code: "capture_failed", message: "Window \(id) not capturable (Screen Recording permission?)")
            }
            return jsonResult(pngResult(from: cgImage))
        }
    }

    private static func pngResult(from cgImage: CGImage) -> Value {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return .object(["error": .string("png encode failed")])
        }
        return .object([
            "width": .int(cgImage.width),
            "height": .int(cgImage.height),
            "image_png_b64": .string(png.base64EncodedString())
        ])
    }
}
