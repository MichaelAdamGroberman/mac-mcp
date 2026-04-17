import Foundation
import MCP

typealias ToolArgs = [String: Value]
typealias ToolHandler = @Sendable (ToolArgs) async throws -> CallTool.Result

struct ToolEntry: Sendable {
    let descriptor: Tool
    let handler: ToolHandler
}

/// Built up at startup, then treated as immutable for the lifetime of the
/// process. `@unchecked Sendable` is safe because all mutation happens
/// before any `@Sendable` closure ever runs.
final class ToolRegistry: @unchecked Sendable {
    private(set) var tools: [ToolEntry] = []
    private var byName: [String: ToolEntry] = [:]

    func add(
        name: String,
        description: String,
        inputSchema: Value,
        handler: @escaping ToolHandler
    ) {
        let descriptor = Tool(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
        let entry = ToolEntry(descriptor: descriptor, handler: handler)
        tools.append(entry)
        byName[name] = entry
    }

    func lookup(_ name: String) -> ToolEntry? {
        byName[name]
    }
}

struct MacMCPError: Error {
    let code: String
    let message: String
}

enum Schema {
    static func object(
        properties: [String: Value],
        required: [String] = []
    ) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> Value {
        var dict: [String: Value] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues {
            dict["enum"] = .array(enumValues.map { .string($0) })
        }
        return .object(dict)
    }

    static func int(_ description: String) -> Value {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    static func bool(_ description: String) -> Value {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    static func array(items: Value, description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": items,
            "description": .string(description)
        ])
    }
}

extension ToolArgs {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func requiredString(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue, !v.isEmpty else {
            throw MacMCPError(code: "missing_arg", message: "Missing required string '\(key)'")
        }
        return v
    }

    func int(_ key: String) -> Int? {
        if let i = self[key]?.intValue { return i }
        if let d = self[key]?.doubleValue { return Int(d) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }
}
