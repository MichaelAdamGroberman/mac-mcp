import Foundation
import MCP
import MacMCPCore

enum TerminalTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "terminal",
            description: "Drive iTerm2 or Terminal.app: open_window, run_command, send_text, get_active_text, list_sessions.",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which terminal action.",
                    enumValues: ["open_window", "run_command", "send_text", "get_active_text", "list_sessions"]),
                "target": Schema.string("Which terminal app.",
                    enumValues: ["iterm", "terminal"]),
                "command": Schema.string("Shell command (run_command). Will be executed verbatim in the active session."),
                "text": Schema.string("Raw text to send (send_text) — no implicit newline."),
                "newline": Schema.bool("Append \\n after text (send_text, default false)."),
                "profile": Schema.string("iTerm2 profile name (open_window, optional).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            let target = args.string("target") ?? "iterm"
            switch (target, action) {
            case ("iterm", "open_window"):
                return try iterm_openWindow(profile: args.string("profile"))
            case ("iterm", "run_command"):
                return try iterm_runCommand(try args.requiredString("command"))
            case ("iterm", "send_text"):
                return try iterm_sendText(try args.requiredString("text"),
                                          newline: args.bool("newline") ?? false)
            case ("iterm", "get_active_text"):
                return try iterm_getActiveText()
            case ("iterm", "list_sessions"):
                return try iterm_listSessions()
            case ("terminal", "open_window"):
                return try terminal_openWindow()
            case ("terminal", "run_command"):
                return try terminal_runCommand(try args.requiredString("command"))
            case ("terminal", "send_text"):
                return try terminal_sendText(try args.requiredString("text"),
                                             newline: args.bool("newline") ?? false)
            case ("terminal", "get_active_text"):
                return try terminal_getActiveText()
            case ("terminal", "list_sessions"):
                return try terminal_listSessions()
            default:
                throw MacMCPError(code: "bad_action", message: "Unsupported \(target)/\(action)")
            }
        }
    }

    // MARK: - iTerm2

    private static func iterm_openWindow(profile: String?) throws -> CallTool.Result {
        let template = (profile?.isEmpty == false) ? """
        tell application "iTerm"
            activate
            create window with profile "{{profile}}"
            return (id of current window) as string
        end tell
        """ : """
        tell application "iTerm"
            activate
            create window with default profile
            return (id of current window) as string
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: ["profile": profile ?? ""])
        return jsonResult(.object(["window_id": .string(desc.stringValue ?? "")]))
    }

    private static func iterm_runCommand(_ cmd: String) throws -> CallTool.Result {
        let template = """
        tell application "iTerm"
            activate
            tell current session of current window
                write text "{{cmd}}"
            end tell
            return "ok"
        end tell
        """
        _ = try ScriptCache.shared.execute(template, params: ["cmd": cmd])
        return jsonResult(.object(["ran": .bool(true)]))
    }

    private static func iterm_sendText(_ text: String, newline: Bool) throws -> CallTool.Result {
        let template = newline ? """
        tell application "iTerm"
            tell current session of current window
                write text "{{t}}"
            end tell
            return "ok"
        end tell
        """ : """
        tell application "iTerm"
            tell current session of current window
                write text "{{t}}" without newline
            end tell
            return "ok"
        end tell
        """
        _ = try ScriptCache.shared.execute(template, params: ["t": text])
        return jsonResult(.object(["sent": .int(text.count), "newline": .bool(newline)]))
    }

    private static func iterm_getActiveText() throws -> CallTool.Result {
        let template = """
        tell application "iTerm"
            tell current session of current window
                return contents
            end tell
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.object(["text": .string(desc.stringValue ?? "")]))
    }

    private static func iterm_listSessions() throws -> CallTool.Result {
        let template = """
        tell application "iTerm"
            set out to {}
            repeat with w in windows
                set wi to (id of w) as string
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set end of out to (wi & "\t" & ((tty of s) as string) & "\t" & ((name of s) as string))
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.array(MailTool.parseTSVList(desc, fields: ["window_id", "tty", "name"])))
    }

    // MARK: - Terminal.app

    private static func terminal_openWindow() throws -> CallTool.Result {
        let template = """
        tell application "Terminal"
            activate
            do script ""
            return (id of front window) as string
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.object(["window_id": .string(desc.stringValue ?? "")]))
    }

    private static func terminal_runCommand(_ cmd: String) throws -> CallTool.Result {
        let template = """
        tell application "Terminal"
            activate
            do script "{{cmd}}" in front window
            return "ok"
        end tell
        """
        _ = try ScriptCache.shared.execute(template, params: ["cmd": cmd])
        return jsonResult(.object(["ran": .bool(true)]))
    }

    private static func terminal_sendText(_ text: String, newline: Bool) throws -> CallTool.Result {
        // Terminal.app's `do script` always runs as a command. For raw text without
        // execution, use System Events keystroke into the focused tab.
        let payload = newline ? text + "\n" : text
        let template = """
        tell application "Terminal" to activate
        tell application "System Events"
            keystroke "{{t}}"
        end tell
        return "ok"
        """
        _ = try ScriptCache.shared.execute(template, params: ["t": payload])
        return jsonResult(.object(["sent": .int(text.count), "newline": .bool(newline)]))
    }

    private static func terminal_getActiveText() throws -> CallTool.Result {
        let template = """
        tell application "Terminal"
            return (contents of front tab of front window) as string
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.object(["text": .string(desc.stringValue ?? "")]))
    }

    private static func terminal_listSessions() throws -> CallTool.Result {
        let template = """
        tell application "Terminal"
            set out to {}
            repeat with w in windows
                set wi to (id of w) as string
                repeat with t in tabs of w
                    set end of out to (wi & "\t" & ((tty of t) as string) & "\t" & ((custom title of t) as string))
                end repeat
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.array(MailTool.parseTSVList(desc, fields: ["window_id", "tty", "title"])))
    }
}
