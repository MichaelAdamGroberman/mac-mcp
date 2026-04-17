import Foundation
import MCP
import MacMCPCore

enum MessagesTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "messages",
            description: "Messages.app actions: send, list_recent. Note: list_recent requires Full Disk Access (reads chat.db).",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which Messages action.", enumValues: ["send", "list_recent"]),
                "to": Schema.string("Recipient phone, email, or contact name (send)."),
                "body": Schema.string("Message body (send)."),
                "service": Schema.string("Service: 'iMessage' (default) or 'SMS' (send)."),
                "limit": Schema.int("Max recent messages (list_recent, default 25, cap 200).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "send":
                return try send(args)
            case "list_recent":
                return try listRecent(limit: min(args.int("limit") ?? 25, 200))
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown messages action: \(action)")
            }
        }
    }

    private static func send(_ args: ToolArgs) throws -> CallTool.Result {
        let to = try args.requiredString("to")
        let body = try args.requiredString("body")
        let service = args.string("service") ?? "iMessage"

        let template = """
        tell application "Messages"
            set targetService to 1st service whose service type = {{svc}}
            set targetBuddy to buddy "{{to}}" of targetService
            send "{{body}}" to targetBuddy
            return "sent"
        end tell
        """
        let svcLit = (service.lowercased() == "sms") ? "SMS" : "iMessage"
        let desc = try ScriptCache.shared.execute(template, params: [
            "svc": svcLit, "to": to, "body": body
        ])
        return jsonResult(.object(["status": .string(desc.stringValue ?? "unknown")]))
    }

    private static func listRecent(limit: Int) throws -> CallTool.Result {
        let dbPath = (NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath as String)
        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            throw MacMCPError(
                code: "tcc_full_disk_access_denied",
                message: "Grant Full Disk Access to MacMCP to read \(dbPath)."
            )
        }
        // Use sqlite3 CLI to avoid linking SQLite at build time. Read-only mode.
        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [
            "-readonly",
            "-separator", "\t",
            dbPath,
            """
            SELECT
              datetime(message.date/1000000000 + strftime('%s','2001-01-01'),'unixepoch','localtime') AS ts,
              CASE WHEN message.is_from_me=1 THEN 'me' ELSE COALESCE(handle.id,'?') END AS who,
              COALESCE(message.text,'') AS body
            FROM message
            LEFT JOIN handle ON message.handle_id = handle.ROWID
            ORDER BY message.date DESC
            LIMIT \(limit);
            """
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map { line -> Value in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return .object([
                "ts": .string(parts.indices.contains(0) ? parts[0] : ""),
                "from": .string(parts.indices.contains(1) ? parts[1] : ""),
                "body": .string(parts.indices.contains(2) ? parts[2] : "")
            ])
        }
        return jsonResult(.array(rows))
    }
}
