import XCTest
@testable import MacMCPCore

final class PathPolicyTests: XCTestCase {
    func testAllowRootMatchesAndDeniesSiblings() throws {
        let p = PathPolicy(allowRoots: ["/Users/me"], denyRoots: PathPolicy.defaultDenyRoots)
        XCTAssertNoThrow(try p.check(path: "/Users/me/file.txt", mode: .read))
        XCTAssertNoThrow(try p.check(path: "/Users/me/sub/dir/file", mode: .read))
        XCTAssertThrowsError(try p.check(path: "/Users/other/file.txt", mode: .read)) { err in
            XCTAssertTrue(err is PathPolicyError)
        }
    }

    func testDenyRootBeatsAllowRoot() throws {
        let p = PathPolicy(allowRoots: ["/"], denyRoots: ["/System"])
        XCTAssertThrowsError(try p.check(path: "/System/Library/Frameworks", mode: .read))
    }

    func testTraversalIsNormalized() throws {
        let p = PathPolicy(allowRoots: ["/Users/me"], denyRoots: ["/etc"])
        XCTAssertThrowsError(try p.check(path: "/Users/me/../../etc/passwd", mode: .read))
    }

    func testEnvDefaultsToHome() throws {
        let p = PathPolicy.fromEnvironment(env: [:])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(p.allowRoots.contains(home))
        XCTAssertTrue(p.denyRoots.contains("/System"))
    }

    func testEnvOverrideAllow() throws {
        let p = PathPolicy.fromEnvironment(env: ["MAC_MCP_FS_ALLOW": "/tmp:/var/folders"])
        // /tmp and /var are macOS symlinks into /private; canonicalisation may or
        // may not collapse them depending on Swift's URL behavior. Check semantically.
        XCTAssertEqual(p.allowRoots.count, 2)
        XCTAssertTrue(p.allowRoots.allSatisfy { $0.hasSuffix("/tmp") || $0.hasSuffix("/var/folders") })
    }

    func testWriteToNonexistentLeafChecksParent() throws {
        // Use the real home dir so the parent actually exists on this machine.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = PathPolicy(allowRoots: [home], denyRoots: [])
        XCTAssertNoThrow(try p.check(path: "\(home)/new-file-that-doesnt-exist.txt", mode: .write))
    }
}
