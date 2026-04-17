import Foundation
import ApplicationServices

enum Permissions {
    static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requireAccessibility() throws {
        guard accessibilityTrusted() else {
            throw MacMCPError(
                code: "tcc_accessibility_denied",
                message: "Grant Accessibility to MacMCP in System Settings → Privacy & Security → Accessibility, then restart Claude Desktop."
            )
        }
    }

    /// Prompt the user via the system dialog to grant Accessibility.
    /// Only call this from a manual one-shot, not from inside a stdio handler
    /// (it would block the MCP loop).
    static func promptForAccessibility() {
        // Use the documented literal key directly to dodge Swift 6's
        // "global var capture" diagnostic on the imported CFString constant.
        let opts: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
