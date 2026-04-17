import Foundation

final class AuditLog: @unchecked Sendable {
    static let shared = AuditLog()

    private let queue = DispatchQueue(label: "mac-mcp.audit", qos: .utility)
    private var handle: FileHandle?
    private var url: URL?
    private let maxBytes: UInt64 = 10 * 1024 * 1024
    private var minLevel: Int = 1   // info
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let levels: [String: Int] = [
        "debug": 0, "info": 1, "warn": 2, "error": 3
    ]

    func start(level: String) {
        queue.sync {
            minLevel = AuditLog.levels[level.lowercased()] ?? 1
            let logsDir = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/mac-mcp", isDirectory: true)
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let logURL = logsDir.appendingPathComponent("audit.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            self.url = logURL
            self.handle = try? FileHandle(forWritingTo: logURL)
            _ = try? self.handle?.seekToEnd()
            rotateIfNeededLocked()
        }
    }

    func debug(_ msg: String, meta: [String: String]) { write(level: 0, msg: msg, meta: meta) }
    func info(_ msg: String, meta: [String: String]) { write(level: 1, msg: msg, meta: meta) }
    func warn(_ msg: String, meta: [String: String]) { write(level: 2, msg: msg, meta: meta) }
    func error(_ msg: String, meta: [String: String]) { write(level: 3, msg: msg, meta: meta) }

    private func write(level: Int, msg: String, meta: [String: String]) {
        guard level >= minLevel else { return }
        queue.async { [self] in
            let levelStr = ["debug", "info", "warn", "error"][level]
            var record: [String: Any] = [
                "ts": isoFormatter.string(from: Date()),
                "level": levelStr,
                "msg": msg
            ]
            if !meta.isEmpty { record["meta"] = meta }
            guard
                let data = try? JSONSerialization.data(withJSONObject: record),
                let line = String(data: data, encoding: .utf8)
            else { return }
            try? handle?.write(contentsOf: Data((line + "\n").utf8))
            rotateIfNeededLocked()
        }
    }

    private func rotateIfNeededLocked() {
        guard let url, let handle else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        guard size >= maxBytes else { return }
        try? handle.close()
        let rotated = url.deletingPathExtension()
            .appendingPathExtension("\(Int(Date().timeIntervalSince1970)).log")
        try? FileManager.default.moveItem(at: url, to: rotated)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: url)
    }
}
