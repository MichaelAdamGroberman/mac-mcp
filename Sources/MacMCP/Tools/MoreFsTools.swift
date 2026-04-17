import Foundation
import AppKit
import MCP
import MacMCPCore

/// Extra filesystem tools beyond the core 11: batch read, in-place edit, PDF write.
enum MoreFsTools {
    static let maxBatchFiles = 50
    static let maxBatchTotalBytes = 10 * 1024 * 1024

    static func register(into r: ToolRegistry) {
        let policy = PathPolicy.fromEnvironment()
        register_read_many(into: r, policy: policy)
        register_edit(into: r, policy: policy)
        register_write_pdf(into: r, policy: policy)
    }

    // MARK: - fs_read_many

    private static func register_read_many(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_read_many",
            description: "Read multiple files in one call. Cap: \(maxBatchFiles) files / \(maxBatchTotalBytes / 1024 / 1024) MB total. Per-file errors are reported per-entry, not as the whole call failing.",
            inputSchema: Schema.object(properties: [
                "paths": Schema.array(items: Schema.string("Path"), description: "Paths to read."),
                "as": Schema.string("Encoding for all files.", enumValues: ["text", "base64"])
            ], required: ["paths"])
        ) { args in
            guard case .array(let raw) = args["paths"] else {
                throw MacMCPError(code: "missing_arg", message: "paths array required")
            }
            let paths = raw.compactMap { $0.stringValue }
            if paths.count > maxBatchFiles {
                throw MacMCPError(code: "batch_too_big",
                                  message: "got \(paths.count) paths, cap is \(maxBatchFiles)")
            }
            let mode = args.string("as") ?? "text"

            var results: [Value] = []
            var totalBytes = 0
            for raw in paths {
                if totalBytes >= maxBatchTotalBytes {
                    results.append(.object([
                        "path": .string(raw),
                        "error": .string("batch_total_cap_reached"),
                        "skipped": .bool(true)
                    ]))
                    continue
                }
                do {
                    let url = try guarded(policy: policy, path: raw, mode: .read)
                    let data = try Data(contentsOf: url)
                    let take = min(data.count, maxBatchTotalBytes - totalBytes)
                    let payload = data.prefix(take)
                    totalBytes += take

                    var entry: [String: Value] = [
                        "path": .string(url.path),
                        "size": .int(data.count),
                        "bytes_returned": .int(take)
                    ]
                    if mode == "base64" {
                        entry["base64"] = .string(payload.base64EncodedString())
                    } else if let s = String(data: payload, encoding: .utf8) {
                        entry["text"] = .string(s)
                    } else {
                        entry["error"] = .string("not_utf8")
                        entry["base64"] = .string(payload.base64EncodedString())
                    }
                    results.append(.object(entry))
                } catch let e as PathPolicyError {
                    results.append(.object(["path": .string(raw), "error": .string(e.code), "message": .string(e.description)]))
                } catch {
                    results.append(.object(["path": .string(raw), "error": .string("read_failed"), "message": .string(String(describing: error))]))
                }
            }
            return jsonResult(.object([
                "count": .int(results.count),
                "total_bytes": .int(totalBytes),
                "files": .array(results)
            ]))
        }
    }

    // MARK: - fs_edit

    private static func register_edit(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_edit",
            description: "Find/replace inside a file. Atomic write. Returns count of replacements actually made. Use the safe-fs-edit skill to snapshot first.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("File path."),
                "find": Schema.string("Substring to find."),
                "replace": Schema.string("Replacement string."),
                "occurrences": Schema.string("Which matches to replace.",
                                             enumValues: ["all", "first", "last"]),
                "expect_count": Schema.int("If set, fail unless exactly this many matches were replaced (sanity guard).")
            ], required: ["path", "find", "replace"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let find = try args.requiredString("find")
            let replace = args.string("replace") ?? ""
            let mode = args.string("occurrences") ?? "all"

            let original = try String(contentsOf: url, encoding: .utf8)
            let occurrenceCount = countOccurrences(of: find, in: original)
            let updated: String
            switch mode {
            case "all":
                updated = original.replacingOccurrences(of: find, with: replace)
            case "first":
                if let range = original.range(of: find) {
                    updated = original.replacingCharacters(in: range, with: replace)
                } else {
                    updated = original
                }
            case "last":
                if let range = original.range(of: find, options: .backwards) {
                    updated = original.replacingCharacters(in: range, with: replace)
                } else {
                    updated = original
                }
            default:
                throw MacMCPError(code: "bad_mode", message: "occurrences must be all|first|last")
            }
            let actualReplaced = (mode == "all") ? occurrenceCount : (occurrenceCount > 0 ? 1 : 0)

            if let expected = args.int("expect_count"), expected != actualReplaced {
                throw MacMCPError(
                    code: "expect_count_mismatch",
                    message: "expected \(expected) replacements, would have made \(actualReplaced) — refusing to write"
                )
            }

            try updated.write(to: url, atomically: true, encoding: .utf8)
            return jsonResult(.object([
                "path": .string(url.path),
                "matches_found": .int(occurrenceCount),
                "replacements_made": .int(actualReplaced),
                "new_size": .int(updated.utf8.count)
            ]))
        }
    }

    // MARK: - fs_write_pdf

    private static func register_write_pdf(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_write_pdf",
            description: "Render text as a PDF and write it. Page sizes: letter (default), a4, legal. Plain text only — wrap in markdown elsewhere if you need formatting.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Destination path (.pdf)."),
                "text": Schema.string("Plain-text content (UTF-8)."),
                "page_size": Schema.string("Page size.", enumValues: ["letter", "a4", "legal"]),
                "font_size": Schema.int("Font size (default 11, range 6..72).")
            ], required: ["path", "text"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let text = try args.requiredString("text")
            let fontSize = max(6, min(args.int("font_size") ?? 11, 72))
            let pageRect: CGRect = {
                switch args.string("page_size") ?? "letter" {
                case "a4":     return CGRect(x: 0, y: 0, width: 595.28, height: 841.89) // 210x297mm @72dpi
                case "legal":  return CGRect(x: 0, y: 0, width: 612, height: 1008)
                default:       return CGRect(x: 0, y: 0, width: 612, height: 792)        // US Letter
                }
            }()
            let margin: CGFloat = 54   // 0.75in
            let usable = pageRect.insetBy(dx: margin, dy: margin)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Menlo", size: CGFloat(fontSize)) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular),
                .foregroundColor: NSColor.black
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)

            var box = pageRect
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw MacMCPError(code: "pdf_init_failed", message: "could not create PDF context for \(url.path)")
            }

            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            let prevCtx = NSGraphicsContext.current
            NSGraphicsContext.current = nsCtx
            defer { NSGraphicsContext.current = prevCtx }

            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            var charIndex = 0
            let totalChars = attributed.length
            var pages = 0
            while charIndex < totalChars {
                ctx.beginPDFPage(nil)
                let path = CGMutablePath()
                path.addRect(usable)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(charIndex, 0), path, nil)
                CTFrameDraw(frame, ctx)
                let visible = CTFrameGetVisibleStringRange(frame)
                charIndex += visible.length
                if visible.length == 0 { break } // safety: avoid infinite loop on unrenderable input
                ctx.endPDFPage()
                pages += 1
                if pages > 1000 { break }
            }
            ctx.closePDF()

            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return jsonResult(.object([
                "path": .string(url.path),
                "pages": .int(pages),
                "size": .int(size)
            ]))
        }
    }

    // MARK: - helpers

    private static func guarded(policy: PathPolicy, path: String, mode: PathPolicy.Mode) throws -> URL {
        do {
            return try policy.check(path: path, mode: mode)
        } catch let e as PathPolicyError {
            throw MacMCPError(code: e.code, message: e.description)
        }
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack[...]
        while let r = search.range(of: needle) {
            count += 1
            search = search[r.upperBound...]
        }
        return count
    }
}
