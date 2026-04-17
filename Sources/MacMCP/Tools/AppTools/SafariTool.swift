import Foundation
import MCP
import MacMCPCore

enum SafariTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "safari",
            description: "Safari actions: open_url, get_tabs, run_js (run_js requires 'Allow JavaScript from Apple Events' in Develop menu).",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which Safari action.", enumValues: ["open_url", "get_tabs", "run_js"]),
                "url": Schema.string("URL to open (open_url)."),
                "in_new_window": Schema.bool("Open in a new window (open_url, default false)."),
                "js": Schema.string("JavaScript snippet to evaluate on the active tab (run_js).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "open_url":
                return try openURL(args)
            case "get_tabs":
                return try getTabs()
            case "run_js":
                return try runJS(args)
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown safari action: \(action)")
            }
        }
    }

    private static func openURL(_ args: ToolArgs) throws -> CallTool.Result {
        let url = try args.requiredString("url")
        let newWin = args.bool("in_new_window") ?? false
        let template = newWin ? """
        tell application "Safari"
            activate
            make new document with properties {URL:"{{url}}"}
            return "opened"
        end tell
        """ : """
        tell application "Safari"
            activate
            open location "{{url}}"
            return "opened"
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["url": url])
        return jsonResult(.object(["status": .string(desc.stringValue ?? "unknown")]))
    }

    private static func getTabs() throws -> CallTool.Result {
        let template = """
        tell application "Safari"
            set out to {}
            repeat with w in windows
                set wi to (id of w) as string
                repeat with t in tabs of w
                    set end of out to (wi & "\t" & ((index of t) as string) & "\t" & (name of t) & "\t" & (URL of t))
                end repeat
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.array(MailTool.parseTSVList(desc, fields: ["window_id", "tab_index", "title", "url"])))
    }

    private static func runJS(_ args: ToolArgs) throws -> CallTool.Result {
        let js = try args.requiredString("js")
        let template = """
        tell application "Safari"
            tell front window
                set r to do JavaScript "{{js}}" in current tab
                return r as string
            end tell
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["js": js])
        return jsonResult(.object(["result": .string(desc.stringValue ?? "")]))
    }
}
