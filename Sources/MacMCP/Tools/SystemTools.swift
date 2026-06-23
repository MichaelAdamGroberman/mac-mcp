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

            // UNUserNotificationCenter requires an active CFRunLoop to deliver
            // its delegate callbacks; this binary runs under Swift Concurrency
            // without NSApplicationMain, so the runloop never spins. Shell out
            // to osascript instead — it has its own runloop.
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
            }
            var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
            if !subtitle.isEmpty {
                script += " subtitle \"\(esc(subtitle))\""
            }
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let errPipe = Pipe()
            task.standardError = errPipe
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let err = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                throw MacMCPError(
                    code: "notify_failed",
                    message: "osascript exit \(task.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
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

            // NSAlert.runModal() requires the AppKit runloop to be running,
            // which it isn't in a Swift-Concurrency-only binary. Shell out to
            // osascript's `display dialog` — same UI, runs in its own runloop.
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
            }
            let script = """
            display dialog "\(esc(message))" \
                with title "\(esc(title))" \
                default answer "\(esc(defaultValue))" \
                buttons {"\(esc(cancelLabel))", "\(esc(okLabel))"} \
                default button "\(esc(okLabel))"
            """
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            try task.run()
            task.waitUntilExit()
            let stdoutText = String(
                data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // osascript returns: "button returned:OK, text returned:VALUE"
            // (or non-zero exit + 'User canceled.' on stderr if Cancel pressed).
            if task.terminationStatus != 0 {
                return jsonResult(.object([
                    "confirmed": .bool(false),
                    "value": .string("")
                ]))
            }
            var buttonReturned = ""
            var textReturned = ""
            for part in stdoutText.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("button returned:") {
                    buttonReturned = String(trimmed.dropFirst("button returned:".count))
                } else if trimmed.hasPrefix("text returned:") {
                    textReturned = String(trimmed.dropFirst("text returned:".count))
                }
            }
            let confirmed = (buttonReturned == okLabel)
            return jsonResult(.object([
                "confirmed": .bool(confirmed),
                "value": .string(confirmed ? textReturned : "")
            ]))
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
