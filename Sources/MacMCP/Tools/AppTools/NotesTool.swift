import Foundation
import MCP
import MacMCPCore

enum NotesTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "notes",
            description: "Notes.app actions: create, search, append.",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which Notes action.", enumValues: ["create", "search", "append"]),
                "title": Schema.string("Note title (create / append target)."),
                "body": Schema.string("Note body (create / append)."),
                "folder": Schema.string("Folder name (create, optional)."),
                "query": Schema.string("Search text (search)."),
                "limit": Schema.int("Max results (search, default 25, cap 100).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "create":
                return try create(args)
            case "search":
                return try search(query: try args.requiredString("query"),
                                  limit: min(args.int("limit") ?? 25, 100))
            case "append":
                return try append(args)
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown notes action: \(action)")
            }
        }
    }

    private static func create(_ args: ToolArgs) throws -> CallTool.Result {
        let title = try args.requiredString("title")
        let body = args.string("body") ?? ""
        let folder = args.string("folder") ?? ""

        let template = """
        tell application "Notes"
            if "{{folder}}" is "" then
                set targetFolder to default folder of default account
            else
                set targetFolder to first folder whose name is "{{folder}}"
            end if
            set htmlBody to "<h1>{{title}}</h1><p>{{body}}</p>"
            set newNote to make new note at targetFolder with properties {name:"{{title}}", body:htmlBody}
            return (id of newNote) as string
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: [
            "title": title, "body": htmlEscape(body), "folder": folder
        ])
        return jsonResult(.object([
            "created": .bool(true),
            "id": .string(desc.stringValue ?? "")
        ]))
    }

    private static func search(query: String, limit: Int) throws -> CallTool.Result {
        let template = """
        tell application "Notes"
            set out to {}
            set found to (every note whose name contains "{{q}}")
            set n to count of found
            if n > {{limit}} then set n to {{limit}}
            repeat with i from 1 to n
                set m to item i of found
                set end of out to ((name of m) & "\t" & ((id of m) as string))
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["q": query, "limit": "\(limit)"])
        return jsonResult(.array(MailTool.parseTSVList(desc, fields: ["title", "id"])))
    }

    private static func append(_ args: ToolArgs) throws -> CallTool.Result {
        let title = try args.requiredString("title")
        let body = try args.requiredString("body")
        let template = """
        tell application "Notes"
            set target to first note whose name is "{{title}}"
            set body of target to ((body of target) & "<p>{{body}}</p>")
            return "appended"
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: [
            "title": title, "body": htmlEscape(body)
        ])
        return jsonResult(.object(["status": .string(desc.stringValue ?? "unknown")]))
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
