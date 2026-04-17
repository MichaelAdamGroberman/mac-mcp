import Foundation
import MCP

@main
struct MacMCPMain {
    static func main() async throws {
        let logLevel = ProcessInfo.processInfo.environment["MAC_MCP_LOG_LEVEL"] ?? "info"
        AuditLog.shared.start(level: logLevel)
        AuditLog.shared.info("mac-mcp starting", meta: ["pid": "\(getpid())"])

        let server = try await MacMCPServer.make()
        let transport = StdioTransport()

        // Block on stdio. The server runs until the client closes the pipe.
        try await server.start(transport: transport)
        try await server.waitUntilCompleted()
        AuditLog.shared.info("mac-mcp exiting", meta: [:])
    }
}
