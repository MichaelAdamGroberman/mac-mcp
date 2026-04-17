import Foundation
import MCP

/// Apple Shortcuts integration via the shipping `/usr/bin/shortcuts` CLI.
enum ShortcutTools {
    static func register(into r: ToolRegistry) {
        register_list(into: r)
        register_run(into: r)
        register_wait(into: r)
    }

    private static func register_list(into r: ToolRegistry) {
        r.add(
            name: "shortcut_list",
            description: "List all available Apple Shortcuts on this Mac.",
            inputSchema: Schema.object(properties: [
                "folder": Schema.string("Optional folder name to filter to.")
            ])
        ) { args in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            var argv = ["list"]
            if let folder = args.string("folder"), !folder.isEmpty {
                argv += ["--folder-name", folder]
            }
            p.arguments = argv
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let names = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return jsonResult(.object([
                "count": .int(names.count),
                "shortcuts": .array(names.map { .string($0) })
            ]))
        }
    }

    private static func register_run(into r: ToolRegistry) {
        r.add(
            name: "shortcut_run",
            description: "Run an Apple Shortcut by name. Optional input (file path) and output (file path). Times out at 60 s.",
            inputSchema: Schema.object(properties: [
                "name": Schema.string("Shortcut name (must match exactly)."),
                "input_path": Schema.string("Optional input file path passed to the shortcut."),
                "output_path": Schema.string("Optional output file path the shortcut writes to.")
            ], required: ["name"])
        ) { args in
            let name = try args.requiredString("name")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            var argv = ["run", name]
            if let inp = args.string("input_path"), !inp.isEmpty {
                argv += ["--input-path", (inp as NSString).expandingTildeInPath]
            }
            if let out = args.string("output_path"), !out.isEmpty {
                argv += ["--output-path", (out as NSString).expandingTildeInPath]
            }
            p.arguments = argv
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            try p.run()

            let started = Date()
            while p.isRunning && Date().timeIntervalSince(started) < 60 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if p.isRunning {
                p.terminate()
                throw MacMCPError(code: "shortcut_timeout", message: "shortcut '\(name)' did not finish within 60 s")
            }

            let stdoutText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return jsonResult(.object([
                "name": .string(name),
                "exit_code": .int(Int(p.terminationStatus)),
                "stdout": .string(stdoutText),
                "stderr": .string(stderrText)
            ]))
        }
    }

    private static func register_wait(into r: ToolRegistry) {
        r.add(
            name: "wait_ms",
            description: "Synchronously wait for the given number of milliseconds (cap 60000 ms / 60 s). Useful between iphone_mirror or focus_app calls when you need the system to settle before the next action.",
            inputSchema: Schema.object(properties: [
                "ms": Schema.int("Milliseconds to wait (1..60000).")
            ], required: ["ms"])
        ) { args in
            let ms = max(1, min(args.int("ms") ?? 100, 60_000))
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return jsonResult(.object(["waited_ms": .int(ms)]))
        }
    }
}
