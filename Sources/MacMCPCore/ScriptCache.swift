import Foundation
#if canImport(OSAKit)
import OSAKit
#endif

/// Thread-safe cache of compiled OSAKit scripts.
/// Compiling AppleScript once and reusing the OSAScript instance is dramatically
/// faster than spawning `osascript` for every call.
public final class ScriptCache: @unchecked Sendable {
    public static let shared = ScriptCache()

    private let queue = DispatchQueue(label: "mac-mcp.script-cache")
    private var cache: [String: Any] = [:]

    public init() {}

    #if canImport(OSAKit)
    public func script(for source: String) throws -> OSAScript {
        try queue.sync {
            if let s = cache[source] as? OSAScript { return s }
            let s = OSAScript(source: source, language: OSALanguage(forName: "AppleScript"))
            var compileErr: NSDictionary?
            guard s.compileAndReturnError(&compileErr) else {
                let msg = (compileErr?["NSLocalizedDescription"] as? String)
                    ?? "AppleScript compile failed"
                throw NSError(
                    domain: "MacMCP.ScriptCache",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            cache[source] = s
            return s
        }
    }

    /// Execute a cached script and return its primary descriptor.
    public func execute(_ source: String) throws -> NSAppleEventDescriptor {
        let script = try self.script(for: source)
        var execErr: NSDictionary?
        guard let result = script.executeAndReturnError(&execErr) else {
            let msg = (execErr?["NSLocalizedDescription"] as? String)
                ?? "AppleScript execution failed"
            throw NSError(
                domain: "MacMCP.ScriptCache",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
        return result
    }

    /// Execute a parameterized script. Parameters are AppleScript-string-escaped
    /// and substituted via simple `{{name}}` placeholders.
    public func execute(_ template: String, params: [String: String]) throws -> NSAppleEventDescriptor {
        var source = template
        for (k, v) in params {
            source = source.replacingOccurrences(of: "{{\(k)}}", with: AppleScript.escape(v))
        }
        return try execute(source)
    }
    #endif
}

public enum AppleScript {
    /// Escape a string for safe interpolation into an AppleScript string literal.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
