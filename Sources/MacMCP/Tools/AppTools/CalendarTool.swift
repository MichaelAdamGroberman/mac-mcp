import Foundation
import MCP
import MacMCPCore

enum CalendarTool {
    static func register(into r: ToolRegistry) {
        r.add(
            name: "calendar",
            description: "Calendar.app actions: create_event, list_today.",
            inputSchema: Schema.object(properties: [
                "action": Schema.string("Which Calendar action.", enumValues: ["create_event", "list_today"]),
                "calendar": Schema.string("Calendar name (create_event). Defaults to first writable calendar."),
                "title": Schema.string("Event title (create_event)."),
                "start_iso": Schema.string("Start datetime ISO-8601 (create_event), e.g. 2026-04-17T15:00:00."),
                "end_iso": Schema.string("End datetime ISO-8601 (create_event)."),
                "notes": Schema.string("Event notes (create_event, optional).")
            ], required: ["action"])
        ) { args in
            let action = try args.requiredString("action")
            switch action {
            case "create_event":
                return try createEvent(args)
            case "list_today":
                return try listToday()
            default:
                throw MacMCPError(code: "bad_action", message: "Unknown calendar action: \(action)")
            }
        }
    }

    private static func createEvent(_ args: ToolArgs) throws -> CallTool.Result {
        let title = try args.requiredString("title")
        let startISO = try args.requiredString("start_iso")
        let endISO = try args.requiredString("end_iso")
        let cal = args.string("calendar") ?? ""
        let notes = args.string("notes") ?? ""

        let template = """
        tell application "Calendar"
            set targetCalName to "{{cal}}"
            if targetCalName is "" then
                set targetCal to first calendar whose writable is true
            else
                set targetCal to first calendar whose name is targetCalName
            end if
            set startD to (current date)
            set startD's year to (text 1 thru 4 of "{{start}}") as integer
            set startD's month to (text 6 thru 7 of "{{start}}") as integer
            set startD's day to (text 9 thru 10 of "{{start}}") as integer
            set startD's hours to (text 12 thru 13 of "{{start}}") as integer
            set startD's minutes to (text 15 thru 16 of "{{start}}") as integer
            set startD's seconds to 0
            set endD to (current date)
            set endD's year to (text 1 thru 4 of "{{end}}") as integer
            set endD's month to (text 6 thru 7 of "{{end}}") as integer
            set endD's day to (text 9 thru 10 of "{{end}}") as integer
            set endD's hours to (text 12 thru 13 of "{{end}}") as integer
            set endD's minutes to (text 15 thru 16 of "{{end}}") as integer
            set endD's seconds to 0
            tell targetCal
                set ev to make new event with properties {summary:"{{title}}", start date:startD, end date:endD, description:"{{notes}}"}
            end tell
            return (uid of ev) as string
        end tell
        """
        let desc = try ScriptCache.shared.execute(template, params: [
            "cal": cal, "title": title, "start": startISO, "end": endISO, "notes": notes
        ])
        return jsonResult(.object([
            "created": .bool(true),
            "uid": .string(desc.stringValue ?? "")
        ]))
    }

    private static func listToday() throws -> CallTool.Result {
        let template = """
        tell application "Calendar"
            set today to current date
            set today's hours to 0
            set today's minutes to 0
            set today's seconds to 0
            set tomorrow to today + 1 * days
            set out to {}
            repeat with c in calendars
                try
                    set evs to (every event of c whose start date ≥ today and start date < tomorrow)
                    repeat with e in evs
                        set end of out to ((summary of e) & "\t" & ((start date of e) as string) & "\t" & ((end date of e) as string) & "\t" & (name of c))
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        let desc = try ScriptCache.shared.execute(template)
        return jsonResult(.array(MailTool.parseTSVList(desc, fields: ["title", "start", "end", "calendar"])))
    }
}
