import Foundation
import AppKit
import MCP
import MacMCPCore

enum FinderTools {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "reveal_in_finder",
            description: "Reveal a file or directory in Finder.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Absolute path to reveal.")
            ], required: ["path"])
        ) { args in
            let path = try args.requiredString("path")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return jsonResult(.object(["revealed": .bool(true), "path": .string(url.path)]))
        }

        r.add(
            name: "get_finder_selection",
            description: "Return the current Finder selection as an array of file URLs.",
            inputSchema: Schema.object(properties: [:])
        ) { _ in
            #if canImport(OSAKit)
            let descriptor = try ScriptCache.shared.execute("""
                tell application "Finder"
                    set theSelection to selection as alias list
                    set thePaths to {}
                    repeat with anItem in theSelection
                        set end of thePaths to POSIX path of (anItem as text)
                    end repeat
                    return thePaths
                end tell
                """)
            var paths: [Value] = []
            let count = descriptor.numberOfItems
            if count > 0 {
                for i in 1...count {
                    if let s = descriptor.atIndex(i)?.stringValue {
                        paths.append(.string(s))
                    }
                }
            } else if let single = descriptor.stringValue, !single.isEmpty {
                paths.append(.string(single))
            }
            return jsonResult(.array(paths))
            #else
            throw MacMCPError(code: "unsupported", message: "OSAKit unavailable")
            #endif
        }

        r.add(
            name: "set_finder_tags",
            description: "Set Finder tags on a file (replaces existing tags).",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Absolute path of file."),
                "tags": Schema.array(items: Schema.string("Tag name"), description: "Tag names.")
            ], required: ["path", "tags"])
        ) { args in
            let path = try args.requiredString("path")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let tagsValue = args["tags"]
            var tags: [String] = []
            if case .array(let arr) = tagsValue {
                tags = arr.compactMap { $0.stringValue }
            }
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            return jsonResult(.object(["set": .bool(true), "tags": .array(tags.map { .string($0) })]))
        }

        r.add(
            name: "quick_look",
            description: "Open Quick Look preview for one or more paths.",
            inputSchema: Schema.object(properties: [
                "paths": Schema.array(items: Schema.string("Path"), description: "Absolute paths to preview.")
            ], required: ["paths"])
        ) { args in
            var urls: [URL] = []
            if case .array(let arr) = args["paths"] {
                for v in arr {
                    if let s = v.stringValue {
                        urls.append(URL(fileURLWithPath: (s as NSString).expandingTildeInPath))
                    }
                }
            }
            guard !urls.isEmpty else {
                throw MacMCPError(code: "missing_arg", message: "paths required")
            }
            let task = Process()
            task.launchPath = "/usr/bin/qlmanage"
            task.arguments = ["-p"] + urls.map { $0.path }
            try task.run()
            return jsonResult(.object(["previewed": .int(urls.count)]))
        }

        r.add(
            name: "move_to_trash",
            description: "Move a file or directory to the user's Trash (recoverable).",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Absolute path.")
            ], required: ["path"])
        ) { args in
            let path = try args.requiredString("path")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return jsonResult(.object([
                "trashed": .bool(true),
                "trash_url": .string(resulting?.absoluteString ?? "")
            ]))
        }

        r.add(
            name: "spotlight_search",
            description: "Run a Spotlight (NSMetadataQuery) search and return matching paths.",
            inputSchema: Schema.object(properties: [
                "query": Schema.string("Spotlight query, e.g. 'kMDItemDisplayName == \"foo*\"' or plain words."),
                "scope": Schema.string("Optional scope path (defaults to user home)."),
                "limit": Schema.int("Max results (default 50, hard cap 500).")
            ], required: ["query"])
        ) { args in
            let q = try args.requiredString("query")
            let limit = min(args.int("limit") ?? 50, 500)
            let scope = args.string("scope").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let pred = predicate(for: q)
            let results = await runSpotlight(predicate: pred, scope: scope, limit: limit)
            return jsonResult(.array(results))
        }
    }

    @MainActor
    private static func runSpotlight(predicate: NSPredicate, scope: URL?, limit: Int) async -> [Value] {
        let mq = NSMetadataQuery()
        mq.predicate = predicate
        if let scope { mq.searchScopes = [scope] }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: mq,
                queue: .main
            ) { _ in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                cont.resume(returning: ())
            }
            // Hard cap so Spotlight can't hang the tool call.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                if mq.isStarted { mq.stop() }
                cont.resume(returning: ())
            }
            mq.start()
        }
        mq.disableUpdates()
        if mq.isStarted { mq.stop() }

        var results: [Value] = []
        for i in 0..<min(mq.resultCount, limit) {
            if let item = mq.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                results.append(.string(path))
            }
        }
        return results
    }

    private static func predicate(for q: String) -> NSPredicate {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("kMDItem") || trimmed.contains("==") || trimmed.contains("LIKE") {
            return NSPredicate(fromMetadataQueryString: trimmed)
                ?? NSPredicate(format: "kMDItemDisplayName CONTAINS[c] %@", trimmed)
        }
        return NSPredicate(format: "kMDItemDisplayName CONTAINS[c] %@", trimmed)
    }
}
