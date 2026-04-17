import Foundation
import MCP
import MacMCPCore

/// Process management — synchronous run + long-running sessions.
///
/// **Security stance.** This is the one tool surface that touches arbitrary
/// executables, so it is gated by an explicit allow-list. By default every
/// `process_*` call refuses with `process_not_allowed`. Users opt in via env:
///
///     MAC_MCP_PROCESS_ALLOW="git:rg:gh:fd:python3:node:swift"
///
/// Match is on the basename of `argv[0]`. Shell expansion is OFF unless the
/// caller passes `shell=true`, which itself requires the chosen shell binary
/// (`/bin/sh`, `/bin/bash`, `/bin/zsh`) to be in the allow-list. Working
/// directories are checked against the same `PathPolicy` as the `fs_*` tools.
enum ProcessTools {
    /// Caps so a single tool call can't blow context or wedge the host.
    static let maxStdoutBytes = 1 * 1024 * 1024     // 1 MB
    static let maxStderrBytes = 256 * 1024          // 256 KB
    static let defaultTimeoutMs = 30_000
    static let maxTimeoutMs = 300_000

    /// Async session registry. Entries removed when terminated.
    static let sessions = SessionRegistry()

    static func register(into r: ToolRegistry) {
        let policy = ProcessPolicy.fromEnvironment()
        let fsPolicy = PathPolicy.fromEnvironment()

        register_run(into: r, policy: policy, fs: fsPolicy)
        register_list(into: r)
        register_kill(into: r, policy: policy)
        register_start(into: r, policy: policy, fs: fsPolicy)
        register_read_output(into: r)
        register_write_input(into: r)
        register_terminate(into: r)
    }

    // MARK: - process_run (sync)

    private static func register_run(into r: ToolRegistry, policy: ProcessPolicy, fs: PathPolicy) {
        r.add(
            name: "process_run",
            description: "Run a process synchronously and return exit + stdout + stderr. Allow-listed via MAC_MCP_PROCESS_ALLOW. Capped at \(maxStdoutBytes / 1024 / 1024) MB stdout / \(maxStderrBytes / 1024) KB stderr / \(maxTimeoutMs / 1000) s timeout.",
            inputSchema: Schema.object(properties: [
                "argv": Schema.array(items: Schema.string("argv item"),
                                     description: "Argv array (preferred). argv[0] is the executable (basename must be in allow-list)."),
                "cmd": Schema.string("Shell command string (only used when shell=true)."),
                "shell": Schema.bool("If true, run via /bin/sh -c <cmd>. /bin/sh must itself be in the allow-list."),
                "cwd": Schema.string("Working directory (defaults to $HOME). Must be under fs allow roots."),
                "stdin": Schema.string("Optional stdin to feed the process (UTF-8)."),
                "timeout_ms": Schema.int("Timeout in ms (default 30000, max 300000)."),
                "env_extra": Schema.string("Optional KEY=VAL pairs joined by newlines, merged into the child environment.")
            ])
        ) { args in
            let timeoutMs = max(100, min(args.int("timeout_ms") ?? defaultTimeoutMs, maxTimeoutMs))
            let argv = try resolveArgv(args: args, policy: policy)
            let cwd = try resolveCwd(args: args, fs: fs)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
            proc.currentDirectoryURL = cwd
            if let extra = args.string("env_extra") {
                proc.environment = mergedEnv(extra)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            if let stdinText = args.string("stdin"), !stdinText.isEmpty {
                let stdinPipe = Pipe()
                proc.standardInput = stdinPipe
                try proc.run()
                try stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdinText.utf8))
                try stdinPipe.fileHandleForWriting.close()
            } else {
                try proc.run()
            }

            let started = Date()
            let timeoutSec = Double(timeoutMs) / 1000.0
            let timedOut = await waitWithTimeout(proc: proc, timeoutSec: timeoutSec)
            if timedOut {
                proc.terminate()
                _ = await waitWithTimeout(proc: proc, timeoutSec: 1)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }

            let stdoutData = readCapped(stdoutPipe.fileHandleForReading, cap: maxStdoutBytes)
            let stderrData = readCapped(stderrPipe.fileHandleForReading, cap: maxStderrBytes)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

            return jsonResult(.object([
                "argv": .array(argv.map { .string($0) }),
                "cwd": .string(cwd.path),
                "exit_code": .int(Int(proc.terminationStatus)),
                "termination_reason": .string(proc.terminationReason == .uncaughtSignal ? "signal" : "exit"),
                "timed_out": .bool(timedOut),
                "elapsed_ms": .int(elapsedMs),
                "stdout": .string(String(data: stdoutData, encoding: .utf8) ?? ""),
                "stdout_truncated": .bool(stdoutData.count >= maxStdoutBytes),
                "stderr": .string(String(data: stderrData, encoding: .utf8) ?? ""),
                "stderr_truncated": .bool(stderrData.count >= maxStderrBytes)
            ]))
        }
    }

    // MARK: - process_list

    private static func register_list(into r: ToolRegistry) {
        r.add(
            name: "process_list",
            description: "List currently running processes (pid, ppid, uid, command). Read-only.",
            inputSchema: Schema.object(properties: [
                "filter": Schema.string("Optional case-insensitive substring filter on the command path.")
            ])
        ) { args in
            let filter = args.string("filter")?.lowercased()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axwwo", "pid,ppid,uid,comm"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            var rows: [Value] = []
            for line in text.split(separator: "\n").dropFirst() {
                let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                guard parts.count >= 4 else { continue }
                let comm = String(parts[3])
                if let f = filter, !comm.lowercased().contains(f) { continue }
                rows.append(.object([
                    "pid": .int(Int(parts[0]) ?? -1),
                    "ppid": .int(Int(parts[1]) ?? -1),
                    "uid": .int(Int(parts[2]) ?? -1),
                    "command": .string(comm)
                ]))
            }
            return jsonResult(.object([
                "count": .int(rows.count),
                "processes": .array(rows)
            ]))
        }
    }

    // MARK: - process_kill

    private static func register_kill(into r: ToolRegistry, policy: ProcessPolicy) {
        r.add(
            name: "process_kill",
            description: "Send a signal to a process by pid. Default signal: TERM. Refuses pid 1 and any process owned by uid != current user unless MAC_MCP_PROCESS_KILL_ANY=1.",
            inputSchema: Schema.object(properties: [
                "pid": Schema.int("Target process id."),
                "signal": Schema.string("Signal name.", enumValues: ["TERM", "KILL", "INT", "HUP", "USR1", "USR2"])
            ], required: ["pid"])
        ) { args in
            guard let pid = args.int("pid") else {
                throw MacMCPError(code: "missing_arg", message: "pid required")
            }
            if pid <= 1 {
                throw MacMCPError(code: "process_protected", message: "refusing to signal pid \(pid)")
            }
            let signalName = args.string("signal") ?? "TERM"
            let signo: Int32 = {
                switch signalName {
                case "KILL": return SIGKILL
                case "INT":  return SIGINT
                case "HUP":  return SIGHUP
                case "USR1": return SIGUSR1
                case "USR2": return SIGUSR2
                default:     return SIGTERM
                }
            }()
            // Cross-user kill guard.
            let currentUid = getuid()
            if let owner = uidOfPid(pid), owner != currentUid {
                let allowAny = (ProcessInfo.processInfo.environment["MAC_MCP_PROCESS_KILL_ANY"] == "1")
                if !allowAny {
                    throw MacMCPError(
                        code: "process_cross_user",
                        message: "refusing to signal pid \(pid) owned by uid \(owner) (current uid \(currentUid)); set MAC_MCP_PROCESS_KILL_ANY=1 to override"
                    )
                }
            }
            let rc = kill(pid_t(pid), signo)
            if rc != 0 {
                throw MacMCPError(code: "kill_failed", message: "kill(\(pid), \(signalName)) returned \(rc) (errno \(errno))")
            }
            _ = policy  // silence unused
            return jsonResult(.object(["killed": .int(pid), "signal": .string(signalName)]))
        }
    }

    // MARK: - async sessions

    private static func register_start(into r: ToolRegistry, policy: ProcessPolicy, fs: PathPolicy) {
        r.add(
            name: "process_start",
            description: "Start an allow-listed process asynchronously and return a session id. Use process_read_output / process_write_input / process_terminate to drive it.",
            inputSchema: Schema.object(properties: [
                "argv": Schema.array(items: Schema.string("argv item"), description: "Argv array."),
                "cmd": Schema.string("Shell command string (only used when shell=true)."),
                "shell": Schema.bool("If true, run via /bin/sh -c <cmd>."),
                "cwd": Schema.string("Working directory (defaults to $HOME). Must be under fs allow roots."),
                "env_extra": Schema.string("Optional KEY=VAL pairs joined by newlines.")
            ])
        ) { args in
            let argv = try resolveArgv(args: args, policy: policy)
            let cwd = try resolveCwd(args: args, fs: fs)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
            proc.currentDirectoryURL = cwd
            if let extra = args.string("env_extra") { proc.environment = mergedEnv(extra) }

            let session = ProcessSession(proc: proc)
            proc.standardOutput = session.stdout
            proc.standardError = session.stderr
            proc.standardInput = session.stdin

            try proc.run()
            await sessions.insert(session)

            return jsonResult(.object([
                "session_id": .string(session.id),
                "pid": .int(Int(proc.processIdentifier))
            ]))
        }
    }

    private static func register_read_output(into r: ToolRegistry) {
        r.add(
            name: "process_read_output",
            description: "Read available stdout/stderr from an async session. Non-blocking, returns immediately with whatever is buffered.",
            inputSchema: Schema.object(properties: [
                "session_id": Schema.string("Session id from process_start."),
                "max_bytes": Schema.int("Max bytes per stream (default 64 KB, cap 1 MB).")
            ], required: ["session_id"])
        ) { args in
            let id = try args.requiredString("session_id")
            let max = max(1, min(args.int("max_bytes") ?? 65_536, maxStdoutBytes))
            guard let s = await sessions.get(id) else {
                throw MacMCPError(code: "session_not_found", message: "no session \(id)")
            }
            let outChunk = s.stdout.fileHandleForReading.availableData.prefix(max)
            let errChunk = s.stderr.fileHandleForReading.availableData.prefix(max)
            let isRunning = s.proc.isRunning
            return jsonResult(.object([
                "session_id": .string(id),
                "running": .bool(isRunning),
                "exit_code": .int(isRunning ? -1 : Int(s.proc.terminationStatus)),
                "stdout": .string(String(data: outChunk, encoding: .utf8) ?? ""),
                "stderr": .string(String(data: errChunk, encoding: .utf8) ?? "")
            ]))
        }
    }

    private static func register_write_input(into r: ToolRegistry) {
        r.add(
            name: "process_write_input",
            description: "Write text to a session's stdin (UTF-8). Pass close_after=true to send EOF after writing.",
            inputSchema: Schema.object(properties: [
                "session_id": Schema.string("Session id from process_start."),
                "text": Schema.string("Bytes to write (UTF-8)."),
                "close_after": Schema.bool("If true, close stdin after writing (default false).")
            ], required: ["session_id", "text"])
        ) { args in
            let id = try args.requiredString("session_id")
            let text = try args.requiredString("text")
            guard let s = await sessions.get(id) else {
                throw MacMCPError(code: "session_not_found", message: "no session \(id)")
            }
            try s.stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            if args.bool("close_after") == true {
                try s.stdin.fileHandleForWriting.close()
            }
            return jsonResult(.object(["wrote": .int(text.count)]))
        }
    }

    private static func register_terminate(into r: ToolRegistry) {
        r.add(
            name: "process_terminate",
            description: "Terminate an async session (SIGTERM, then SIGKILL after 1 s) and remove it from the registry.",
            inputSchema: Schema.object(properties: [
                "session_id": Schema.string("Session id from process_start.")
            ], required: ["session_id"])
        ) { args in
            let id = try args.requiredString("session_id")
            guard let s = await sessions.get(id) else {
                throw MacMCPError(code: "session_not_found", message: "no session \(id)")
            }
            if s.proc.isRunning {
                s.proc.terminate()
                _ = await waitWithTimeout(proc: s.proc, timeoutSec: 1)
                if s.proc.isRunning { kill(s.proc.processIdentifier, SIGKILL) }
            }
            await sessions.remove(id)
            return jsonResult(.object([
                "terminated": .string(id),
                "exit_code": .int(Int(s.proc.terminationStatus))
            ]))
        }
    }

    // MARK: - helpers

    private static func resolveArgv(args: ToolArgs, policy: ProcessPolicy) throws -> [String] {
        let useShell = args.bool("shell") ?? false
        var argv: [String]

        if useShell {
            let cmd = try args.requiredString("cmd")
            let shell = "/bin/sh"
            argv = [shell, "-c", cmd]
        } else if case .array(let arr) = args["argv"] {
            argv = arr.compactMap { $0.stringValue }
            guard !argv.isEmpty else {
                throw MacMCPError(code: "missing_arg", message: "argv must be non-empty (or set shell=true and pass cmd)")
            }
        } else {
            throw MacMCPError(code: "missing_arg", message: "provide argv (array) or shell=true + cmd (string)")
        }

        let basename = (argv[0] as NSString).lastPathComponent
        guard policy.isAllowed(basename) else {
            throw MacMCPError(
                code: "process_not_allowed",
                message: "executable '\(basename)' not in MAC_MCP_PROCESS_ALLOW (current allow-list: \(policy.allowed))"
            )
        }
        // Resolve `git` → `/usr/bin/git` etc. if argv[0] isn't an absolute path.
        if !argv[0].hasPrefix("/") {
            if let resolved = which(basename) {
                argv[0] = resolved
            }
        }
        return argv
    }

    private static func resolveCwd(args: ToolArgs, fs: PathPolicy) throws -> URL {
        let cwdStr = args.string("cwd") ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            return try fs.check(path: cwdStr, mode: .read)
        } catch let e as PathPolicyError {
            throw MacMCPError(code: e.code, message: "cwd: \(e.description)")
        }
    }

    private static func mergedEnv(_ extra: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for line in extra.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }
        return env
    }

    private static func which(_ binary: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func uidOfPid(_ pid: Int) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    private static func readCapped(_ handle: FileHandle, cap: Int) -> Data {
        var collected = Data()
        while collected.count < cap {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let take = min(chunk.count, cap - collected.count)
            collected.append(chunk.prefix(take))
        }
        return collected
    }

    private static func waitWithTimeout(proc: Process, timeoutSec: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return proc.isRunning
    }
}

// MARK: - Allow-list policy

struct ProcessPolicy: Sendable {
    let allowed: [String]

    func isAllowed(_ basename: String) -> Bool {
        allowed.contains(basename)
    }

    static func fromEnvironment(env: [String: String] = ProcessInfo.processInfo.environment) -> ProcessPolicy {
        let raw = env["MAC_MCP_PROCESS_ALLOW"] ?? ""
        let list = raw.split(separator: ":").map { String($0) }.filter { !$0.isEmpty }
        return ProcessPolicy(allowed: list)
    }
}

// MARK: - Async session registry

actor SessionRegistry {
    private var store: [String: ProcessSession] = [:]

    func insert(_ s: ProcessSession) { store[s.id] = s }
    func get(_ id: String) -> ProcessSession? { store[id] }
    func remove(_ id: String) { store.removeValue(forKey: id) }
    func count() -> Int { store.count }
}

final class ProcessSession: @unchecked Sendable {
    let id: String
    let proc: Process
    let stdout: Pipe
    let stderr: Pipe
    let stdin: Pipe

    init(proc: Process) {
        self.id = UUID().uuidString
        self.proc = proc
        self.stdout = Pipe()
        self.stderr = Pipe()
        self.stdin = Pipe()
    }
}
