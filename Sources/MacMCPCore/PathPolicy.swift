import Foundation

/// Allow-list / deny-list policy for filesystem tool paths.
///
/// Resolves every requested path through `standardizedFileURL` + `resolvingSymlinksInPath`
/// before deciding, so:
/// - `..` traversal is normalised away
/// - symlinks pointing outside the allow root resolve to their real target and are caught
///   (this is what Desktop Commander's FAQ admits its allow-list does NOT do)
///
/// Defaults: allow `$HOME`, deny everything under `/System`, `/Library`, `/private`,
/// `/usr`, `/bin`, `/sbin`, `/var`, `/etc`, `/dev`. The defaults are intentionally
/// conservative for system safety. Override via env:
///
///   MAC_MCP_FS_ALLOW="/Users/me:/Volumes/Code"     (colon-separated, replaces default)
///   MAC_MCP_FS_DENY_EXTRA="/Users/me/.aws"         (colon-separated, added to defaults)
///
public struct PathPolicy: Sendable {
    public let allowRoots: [String]
    public let denyRoots: [String]

    public static let defaultDenyRoots: [String] = [
        "/System", "/Library", "/private", "/usr", "/bin",
        "/sbin", "/var", "/etc", "/dev"
    ]

    public init(allowRoots: [String], denyRoots: [String]) {
        self.allowRoots = allowRoots.map { Self.canonicalString($0) }
        self.denyRoots = denyRoots.map { Self.canonicalString($0) }
    }

    public static func fromEnvironment(env: [String: String] = ProcessInfo.processInfo.environment) -> PathPolicy {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let allowSpec = env["MAC_MCP_FS_ALLOW"]?
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        let allow = (allowSpec?.isEmpty == false) ? allowSpec! : [home]

        let extraDeny = env["MAC_MCP_FS_DENY_EXTRA"]?
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        let deny = defaultDenyRoots + extraDeny
        return PathPolicy(allowRoots: allow, denyRoots: deny)
    }

    /// Resolve and check. Returns the canonical URL on success; throws on denial.
    /// `mode == .write` allows the leaf to not exist (only the parent must resolve).
    public func check(path: String, mode: Mode) throws -> URL {
        let canonical = try Self.canonicalize(path: path, mode: mode)
        let cp = canonical.path

        for d in denyRoots {
            if cp == d || cp.hasPrefix(d + "/") {
                throw PathPolicyError.denied(
                    "path resolves under denied root '\(d)': \(cp)"
                )
            }
        }
        for a in allowRoots {
            if cp == a || cp.hasPrefix(a + "/") {
                return canonical
            }
        }
        throw PathPolicyError.notAllowed(
            "path '\(cp)' is not under any allow root: \(allowRoots)"
        )
    }

    public enum Mode: Sendable {
        case read
        case write
    }

    /// Canonicalise a path. For write mode, only the parent is required to exist
    /// (we resolve the parent's symlinks and re-attach the leaf).
    static func canonicalize(path: String, mode: Mode) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            throw PathPolicyError.invalid("empty path")
        }
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(expanded)
        }

        let url = URL(fileURLWithPath: absolute)
        if FileManager.default.fileExists(atPath: url.path) || mode == .read {
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        // Write to a path that doesn't exist yet: canonicalise the parent only.
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw PathPolicyError.invalid("parent directory does not exist: \(parent.path)")
        }
        let canonicalParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        return canonicalParent.appendingPathComponent(url.lastPathComponent)
    }

    private static func canonicalString(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public enum PathPolicyError: Error, CustomStringConvertible {
    case denied(String)
    case notAllowed(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .denied(let m), .notAllowed(let m), .invalid(let m): return m
        }
    }

    public var code: String {
        switch self {
        case .denied: return "fs_denied"
        case .notAllowed: return "fs_not_allowed"
        case .invalid: return "fs_invalid_path"
        }
    }
}
