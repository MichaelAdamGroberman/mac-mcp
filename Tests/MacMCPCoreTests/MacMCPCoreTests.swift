import XCTest
@testable import MacMCPCore

final class MacMCPCoreTests: XCTestCase {
    func testAppleScriptEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AppleScript.escape(#"hello"world"#), #"hello\"world"#)
        XCTAssertEqual(AppleScript.escape(#"path\to\file"#), #"path\\to\\file"#)
        XCTAssertEqual(AppleScript.escape("plain"), "plain")
    }

    func testVersionPresent() {
        XCTAssertFalse(MacMCPCoreInfo.version.isEmpty)
    }
}
