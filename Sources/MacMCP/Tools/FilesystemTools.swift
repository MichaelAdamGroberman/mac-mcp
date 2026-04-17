import Foundation
import CoreServices
import Darwin
import MCP
import MacMCPCore

enum FilesystemTools {
    /// Hard caps so a single tool call can't blow context or memory.
    static let maxReadBytes      = 10 * 1024 * 1024   // 10 MB
    static let defaultReadBytes  =  1 * 1024 * 1024   //  1 MB
    static let maxListEntries    = 5_000
    static let defaultListEntries = 500
    static let maxWriteBytes     = 50 * 1024 * 1024   // 50 MB

    static func register(into r: ToolRegistry) {
        let policy = PathPolicy.fromEnvironment()
        register_read(into: r, policy: policy)
        register_write(into: r, policy: policy)
        register_list(into: r, policy: policy)
        register_stat(into: r, policy: policy)
        register_copy_move(into: r, policy: policy)
        register_make_dir(into: r, policy: policy)
        register_delete(into: r, policy: policy)
        register_watch(into: r, policy: policy)
        register_xattr(into: r, policy: policy)
    }

    // MARK: - read

    private static func register_read(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_read",
            description: "Read a file. UTF-8 text by default; pass as='base64' for binary. Hard cap: \(maxReadBytes / 1024 / 1024) MB.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Absolute or tilde-expanded path."),
                "as": Schema.string("Encoding.", enumValues: ["text", "base64"]),
                "offset": Schema.int("Byte offset (default 0)."),
                "max_bytes": Schema.int("Max bytes to return (default 1 MB, cap 10 MB).")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .read)
            let mode = args.string("as") ?? "text"
            let offset = max(0, args.int("offset") ?? 0)
            let limit = max(1, min(args.int("max_bytes") ?? defaultReadBytes, maxReadBytes))

            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw MacMCPError(code: "fs_read_failed", message: String(describing: error))
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: limit)

            let totalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? data.count
            var payload: [String: Value] = [
                "path": .string(url.path),
                "size_total": .int(totalSize),
                "bytes_returned": .int(data.count),
                "offset": .int(offset),
                "truncated": .bool(offset + data.count < totalSize)
            ]
            if mode == "base64" {
                payload["base64"] = .string(data.base64EncodedString())
            } else {
                guard let s = String(data: data, encoding: .utf8) else {
                    throw MacMCPError(code: "fs_not_utf8", message: "file is not valid UTF-8 — re-call with as='base64'")
                }
                payload["text"] = .string(s)
            }
            return jsonResult(.object(payload))
        }
    }

    // MARK: - write

    private static func register_write(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_write",
            description: "Write a file. Provide exactly one of {text, base64}. Modes: create (default; fails if exists), overwrite, append.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Absolute or tilde-expanded path."),
                "text": Schema.string("UTF-8 text payload."),
                "base64": Schema.string("Base64-encoded binary payload."),
                "mode": Schema.string("Write mode.", enumValues: ["create", "overwrite", "append"])
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let mode = args.string("mode") ?? "create"

            let data: Data
            if let text = args.string("text") {
                data = Data(text.utf8)
            } else if let b64 = args.string("base64"), let d = Data(base64Encoded: b64) {
                data = d
            } else {
                throw MacMCPError(code: "missing_arg", message: "provide one of: text, base64")
            }
            guard data.count <= maxWriteBytes else {
                throw MacMCPError(code: "fs_too_big", message: "payload \(data.count) > cap \(maxWriteBytes) bytes")
            }

            let exists = FileManager.default.fileExists(atPath: url.path)
            switch mode {
            case "create":
                if exists { throw MacMCPError(code: "fs_exists", message: "path exists; use mode='overwrite' or 'append'") }
                try data.write(to: url, options: .atomic)
            case "overwrite":
                try data.write(to: url, options: .atomic)
            case "append":
                if exists {
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            default:
                throw MacMCPError(code: "bad_mode", message: "unknown mode: \(mode)")
            }
            return jsonResult(.object([
                "path": .string(url.path),
                "bytes_written": .int(data.count),
                "mode": .string(mode)
            ]))
        }
    }

    // MARK: - list

    private static func register_list(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_list",
            description: "List directory entries. Returns name, kind (file|dir|symlink), size, mtime. Optional glob filter.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Directory path."),
                "recursive": Schema.bool("Walk subdirectories (default false)."),
                "max_entries": Schema.int("Cap on returned entries (default 500, cap 5000)."),
                "glob": Schema.string("Optional fnmatch glob (e.g. '*.swift').")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .read)
            let recursive = args.bool("recursive") ?? false
            let limit = max(1, min(args.int("max_entries") ?? defaultListEntries, maxListEntries))
            let glob = args.string("glob")

            let fm = FileManager.default
            var iso: ISO8601DateFormatter { ISO8601DateFormatter() }
            let isoFormatter = iso

            let entries: [URL]
            if recursive {
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                var collected: [URL] = []
                while let next = enumerator?.nextObject() as? URL, collected.count < limit {
                    collected.append(next)
                }
                entries = collected
            } else {
                entries = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }

            var out: [Value] = []
            var truncated = false
            for entry in entries {
                if out.count >= limit { truncated = true; break }
                if let glob, !fnmatch(glob, entry.lastPathComponent) { continue }

                let vals = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
                ])
                let isSymlink = vals?.isSymbolicLink ?? false
                let isDir = vals?.isDirectory ?? false
                let kind = isSymlink ? "symlink" : (isDir ? "dir" : "file")
                var obj: [String: Value] = [
                    "name": .string(entry.lastPathComponent),
                    "path": .string(entry.path),
                    "kind": .string(kind)
                ]
                if let s = vals?.fileSize { obj["size"] = .int(s) }
                if let m = vals?.contentModificationDate {
                    obj["mtime"] = .string(isoFormatter.string(from: m))
                }
                out.append(.object(obj))
            }
            return jsonResult(.object([
                "path": .string(url.path),
                "count": .int(out.count),
                "truncated": .bool(truncated || entries.count >= limit),
                "entries": .array(out)
            ]))
        }
    }

    // MARK: - stat

    private static func register_stat(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_stat",
            description: "Return path metadata: kind, size, mtime, ctime, atime, perms (octal), owner uid/gid, file flags, symlink target, xattrs (names only).",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Path to stat.")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .read)
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw MacMCPError(code: "fs_stat_failed", message: String(describing: error))
            }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            let kind = isSymlink ? "symlink" : (isDir ? "dir" : "file")
            let isoF = ISO8601DateFormatter()

            var obj: [String: Value] = [
                "path": .string(url.path),
                "kind": .string(kind)
            ]
            if let size = attrs[.size] as? Int { obj["size"] = .int(size) }
            if let m = attrs[.modificationDate] as? Date { obj["mtime"] = .string(isoF.string(from: m)) }
            if let c = attrs[.creationDate] as? Date { obj["ctime"] = .string(isoF.string(from: c)) }
            if let perms = attrs[.posixPermissions] as? NSNumber {
                obj["perms_octal"] = .string(String(perms.intValue, radix: 8))
            }
            if let uid = attrs[.ownerAccountID] as? NSNumber { obj["uid"] = .int(uid.intValue) }
            if let gid = attrs[.groupOwnerAccountID] as? NSNumber { obj["gid"] = .int(gid.intValue) }
            if let owner = attrs[.ownerAccountName] as? String { obj["owner"] = .string(owner) }
            if isSymlink {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                    obj["symlink_target"] = .string(target)
                }
            }
            obj["xattrs"] = .array(listXattrs(url.path).map { .string($0) })
            return jsonResult(.object(obj))
        }
    }

    // MARK: - copy/move

    private static func register_copy_move(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_copy",
            description: "Copy a file or directory. Both src and dst are policy-checked.",
            inputSchema: Schema.object(properties: [
                "src": Schema.string("Source path."),
                "dst": Schema.string("Destination path."),
                "overwrite": Schema.bool("If true and dst exists, overwrite (default false).")
            ], required: ["src", "dst"])
        ) { args in
            let src = try guarded(policy: policy, path: try args.requiredString("src"), mode: .read)
            let dst = try guarded(policy: policy, path: try args.requiredString("dst"), mode: .write)
            let overwrite = args.bool("overwrite") ?? false
            if FileManager.default.fileExists(atPath: dst.path) {
                if overwrite {
                    try FileManager.default.removeItem(at: dst)
                } else {
                    throw MacMCPError(code: "fs_exists", message: "dst exists; pass overwrite=true to replace")
                }
            }
            try FileManager.default.copyItem(at: src, to: dst)
            return jsonResult(.object(["copied": .bool(true), "src": .string(src.path), "dst": .string(dst.path)]))
        }

        r.add(
            name: "fs_move",
            description: "Move or rename a file or directory. Both src and dst are policy-checked.",
            inputSchema: Schema.object(properties: [
                "src": Schema.string("Source path."),
                "dst": Schema.string("Destination path."),
                "overwrite": Schema.bool("If true and dst exists, overwrite (default false).")
            ], required: ["src", "dst"])
        ) { args in
            let src = try guarded(policy: policy, path: try args.requiredString("src"), mode: .write)
            let dst = try guarded(policy: policy, path: try args.requiredString("dst"), mode: .write)
            let overwrite = args.bool("overwrite") ?? false
            if FileManager.default.fileExists(atPath: dst.path) {
                if overwrite {
                    try FileManager.default.removeItem(at: dst)
                } else {
                    throw MacMCPError(code: "fs_exists", message: "dst exists; pass overwrite=true to replace")
                }
            }
            try FileManager.default.moveItem(at: src, to: dst)
            return jsonResult(.object(["moved": .bool(true), "src": .string(src.path), "dst": .string(dst.path)]))
        }
    }

    // MARK: - make_dir

    private static func register_make_dir(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_make_dir",
            description: "Create a directory. parents=true creates intermediate directories as needed.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Directory path to create."),
                "parents": Schema.bool("Create intermediate directories (default true)."),
                "perms_octal": Schema.string("Permissions as octal string, e.g. '755' (default '755').")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let parents = args.bool("parents") ?? true
            let permsOctal = args.string("perms_octal") ?? "755"
            guard let perms = Int(permsOctal, radix: 8) else {
                throw MacMCPError(code: "bad_arg", message: "perms_octal must be an octal string like '755'")
            }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: parents,
                attributes: [.posixPermissions: NSNumber(value: perms)]
            )
            return jsonResult(.object(["created": .string(url.path)]))
        }
    }

    // MARK: - delete

    private static func register_delete(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_delete",
            description: "Delete a file or directory. Default = move to Trash (recoverable). Pass permanent=true to unlink.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Path to delete."),
                "permanent": Schema.bool("If true, unlink (irreversible). Default false (Trash).")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let permanent = args.bool("permanent") ?? false
            if permanent {
                try FileManager.default.removeItem(at: url)
                return jsonResult(.object(["deleted": .bool(true), "permanent": .bool(true), "path": .string(url.path)]))
            } else {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return jsonResult(.object([
                    "deleted": .bool(true),
                    "permanent": .bool(false),
                    "trash_url": .string(resulting?.absoluteString ?? "")
                ]))
            }
        }
    }

    // MARK: - watch

    private static func register_watch(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_watch_once",
            description: "Block until the next FSEvent inside the given path (or timeout). Returns the changed paths.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("Directory or file to watch."),
                "timeout_ms": Schema.int("Max wait in ms (default 30000, cap 600000).")
            ], required: ["path"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .read)
            let timeoutMs = max(100, min(args.int("timeout_ms") ?? 30_000, 600_000))
            let changed = try await waitForFSEvent(at: url.path, timeoutMs: timeoutMs)
            return jsonResult(.object([
                "path": .string(url.path),
                "changed_paths": .array(changed.map { .string($0) }),
                "timed_out": .bool(changed.isEmpty)
            ]))
        }
    }

    // MARK: - xattr

    private static func register_xattr(into r: ToolRegistry, policy: PathPolicy) {
        r.add(
            name: "fs_xattr_get",
            description: "Get a macOS extended attribute as base64. Pass name='*' to list all xattr names.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("File path."),
                "name": Schema.string("xattr name, or '*' to list names only.")
            ], required: ["path", "name"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .read)
            let name = try args.requiredString("name")
            if name == "*" {
                return jsonResult(.object([
                    "path": .string(url.path),
                    "names": .array(listXattrs(url.path).map { .string($0) })
                ]))
            }
            guard let data = getXattr(url.path, name: name) else {
                throw MacMCPError(code: "xattr_missing", message: "no xattr '\(name)' on \(url.path)")
            }
            return jsonResult(.object([
                "path": .string(url.path),
                "name": .string(name),
                "value_b64": .string(data.base64EncodedString()),
                "size": .int(data.count)
            ]))
        }

        r.add(
            name: "fs_xattr_set",
            description: "Set a macOS extended attribute. Provide value_text or value_b64.",
            inputSchema: Schema.object(properties: [
                "path": Schema.string("File path."),
                "name": Schema.string("xattr name."),
                "value_text": Schema.string("UTF-8 text value."),
                "value_b64": Schema.string("Base64 binary value.")
            ], required: ["path", "name"])
        ) { args in
            let url = try guarded(policy: policy, path: try args.requiredString("path"), mode: .write)
            let name = try args.requiredString("name")
            let data: Data
            if let t = args.string("value_text") {
                data = Data(t.utf8)
            } else if let b = args.string("value_b64"), let d = Data(base64Encoded: b) {
                data = d
            } else {
                throw MacMCPError(code: "missing_arg", message: "provide value_text or value_b64")
            }
            guard setXattr(url.path, name: name, data: data) else {
                throw MacMCPError(code: "xattr_set_failed", message: "setxattr failed (errno \(errno))")
            }
            return jsonResult(.object([
                "set": .bool(true),
                "path": .string(url.path),
                "name": .string(name),
                "size": .int(data.count)
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

    private static func listXattrs(_ path: String) -> [String] {
        let len = listxattr(path, nil, 0, 0)
        guard len > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: len)
        let n = listxattr(path, &buf, len, 0)
        guard n > 0 else { return [] }
        let data = Data(bytes: buf, count: n)
        return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private static func getXattr(_ path: String, name: String) -> Data? {
        let len = getxattr(path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var buf = Data(count: len)
        let n = buf.withUnsafeMutableBytes { ptr in
            getxattr(path, name, ptr.baseAddress, len, 0, 0)
        }
        guard n > 0 else { return nil }
        return buf.prefix(n)
    }

    private static func setXattr(_ path: String, name: String, data: Data) -> Bool {
        data.withUnsafeBytes { ptr in
            setxattr(path, name, ptr.baseAddress, data.count, 0, 0) == 0
        }
    }

    private static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        // POSIX fnmatch; pattern characters * ? [ ] supported.
        Darwin.fnmatch(pattern, name, 0) == 0
    }

    /// FSEvents one-shot: returns changed paths after the first event, or [] on timeout.
    private static func waitForFSEvent(at path: String, timeoutMs: Int) async throws -> [String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            let pathsToWatch = [path] as CFArray
            let resumed = ResumeOnce()

            var context = FSEventStreamContext()
            context.info = Unmanaged.passRetained(resumed as AnyObject).toOpaque()

            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info,
                      let cfArr = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]
                else { return }
                let resumed = Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue() as! ResumeOnce
                _ = count
                resumed.fire(cfArr)
            }

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else {
                cont.resume(throwing: MacMCPError(code: "fsevents_failed", message: "FSEventStreamCreate returned nil"))
                return
            }

            let queue = DispatchQueue(label: "mac-mcp.fsevents")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)

            resumed.onFire = { paths in
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                cont.resume(returning: paths)
            }

            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                if resumed.fire([]) {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    cont.resume(returning: [])
                }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        var onFire: (([String]) -> Void)?

        @discardableResult
        func fire(_ paths: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            onFire?(paths)
            return true
        }
    }
}
