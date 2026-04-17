import Foundation
import MCP

enum MacMCPServer {
    static func make() async throws -> Server {
        let server = Server(
            name: "mac-mcp",
            version: "0.2.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        let registry = ToolRegistry()
        WindowTools.register(into: registry)
        FinderTools.register(into: registry)
        FilesystemTools.register(into: registry)
        MoreFsTools.register(into: registry)
        SystemTools.register(into: registry)
        InputTools.register(into: registry)
        ProcessTools.register(into: registry)
        ShortcutTools.register(into: registry)
        MailTool.register(into: registry)
        CalendarTool.register(into: registry)
        MessagesTool.register(into: registry)
        SafariTool.register(into: registry)
        NotesTool.register(into: registry)
        TerminalTool.register(into: registry)
        iPhoneMirrorTool.register(into: registry)

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: registry.tools.map { $0.descriptor })
        }

        await server.withMethodHandler(CallTool.self) { params in
            let toolName = params.name
            let args = params.arguments ?? [:]

            guard let entry = registry.lookup(toolName) else {
                AuditLog.shared.warn("unknown tool", meta: ["tool": toolName])
                return .init(
                    content: [.text("Unknown tool: \(toolName)")],
                    isError: true
                )
            }

            let started = Date()
            do {
                let result = try await entry.handler(args)
                AuditLog.shared.info("tool ok", meta: [
                    "tool": toolName,
                    "ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
                ])
                return result
            } catch let err as MacMCPError {
                AuditLog.shared.warn("tool err", meta: [
                    "tool": toolName,
                    "code": err.code,
                    "msg": err.message
                ])
                return .init(
                    content: [.text("\(err.code): \(err.message)")],
                    isError: true
                )
            } catch {
                AuditLog.shared.error("tool crash", meta: [
                    "tool": toolName,
                    "msg": String(describing: error)
                ])
                return .init(
                    content: [.text("Internal error: \(error)")],
                    isError: true
                )
            }
        }

        return server
    }
}
