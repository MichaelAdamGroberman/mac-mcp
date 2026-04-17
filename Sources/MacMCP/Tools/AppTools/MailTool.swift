import Foundation
import MCP
import MacMCPCore

enum MailTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "mail",
            description: "Mail.app actions: compose, search, list_unread.",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which Mail action to run.", enumValues: ["compose", "search", "list_unread"]),
                "to": Schema.string("Recipient (compose)."),
                "subject": Schema.string("Subject (compose)."),
                "body": Schema.string("Body (compose)."),
                "cc": Schema.string("CC (compose, optional)."),
                "send": Schema.bool("If true, send immediately (compose). Default false: opens draft."),
                "query": Schema.string("Search text (search)."),
                "limit": Schema.int("Max results (search/list_unread, default 25, cap 100).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "compose":
                return try compose(args)
            case "list_unread":
                return try listUnread(limit: min(args.int("limit") ?? 25, 100))
            case "search":
                return try search(query: try args.requiredString("query"),
                                  limit: min(args.int("limit") ?? 25, 100))
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown mail action: \(action)")
            }
        }
    }

    private static func compose(_ args: ToolArgs) throws -> CallTool.Result {
        let to = try args.requiredString("to")
        let subject = args.string("subject") ?? ""
        let body = args.string("body") ?? ""
        let cc = args.string("cc") ?? ""
        let send = args.bool("send") ?? false

        let template = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"{{subject}}", content:"{{body}}", visible:true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"{{to}}"}
                if "{{cc}}" is not "" then
                    make new cc recipient at end of cc recipients with properties {address:"{{cc}}"}
                end if
            end tell
            if "{{send_flag}}" is "true" then
                send newMessage
                return "sent"
            else
                activate
                return "drafted"
            end if
        end tell
        """
        let result = try ScriptCache.shared.execute(template, params: [
            "to": to, "subject": subject, "body": body, "cc": cc,
            "send_flag": send ? "true" : "false"
        ])
        return jsonResult(.object([
            "status": .string(result.stringValue ?? "unknown")
        ]))
    }

    private static func listUnread(limit: Int) throws -> CallTool.Result {
        let template = """
        tell application "Mail"
            set out to {}
            set msgs to (messages of inbox whose read status is false)
            set n to count of msgs
            if n > {{limit}} then set n to {{limit}}
            repeat with i from 1 to n
                set m to item i of msgs
                set end of out to {(subject of m) & "\t" & ((sender of m) as string) & "\t" & ((date received of m) as string)}
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["limit": "\(limit)"])
        return jsonResult(.array(parseTSVList(desc, fields: ["subject", "from", "received"])))
    }

    private static func search(query: String, limit: Int) throws -> CallTool.Result {
        let template = """
        tell application "Mail"
            set out to {}
            set msgs to (messages of inbox whose subject contains "{{q}}")
            set n to count of msgs
            if n > {{limit}} then set n to {{limit}}
            repeat with i from 1 to n
                set m to item i of msgs
                set end of out to {(subject of m) & "\t" & ((sender of m) as string) & "\t" & ((date received of m) as string)}
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["q": query, "limit": "\(limit)"])
        return jsonResult(.array(parseTSVList(desc, fields: ["subject", "from", "received"])))
    }

    static func parseTSVList(_ desc: NSAppleEventDescriptor, fields: [String]) -> [Value] {
        var out: [Value] = []
        let count = desc.numberOfItems
        if count == 0 { return out }
        for i in 1...count {
            guard let row = desc.atIndex(i)?.stringValue else { continue }
            let parts = row.components(separatedBy: "\t")
            var obj: [String: Value] = [:]
            for (j, f) in fields.enumerated() {
                obj[f] = .string(j < parts.count ? parts[j] : "")
            }
            out.append(.object(obj))
        }
        return out
    }
}
