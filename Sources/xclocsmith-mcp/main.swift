import Foundation
import XCLocSmithKit

/// An MCP server exposing xclocSmith over stdio.
///
/// JSON-RPC 2.0, newline-delimited, spoken directly rather than through an SDK —
/// the protocol surface needed here is small, and the package stays free of
/// dependencies so `swift build` remains the whole install story.
///
/// Why this exists alongside the CLI: over a shell, anything that can run
/// `xclocsmith` can run `xclocsmith prune --apply --force`. Here the reading
/// tools and the writing tools are separate, annotated tools, so a host can
/// grant one set and confirm the other.
enum MCP {
    static let protocolVersion = "2025-06-18"
    static let serverName = "xclocsmith"
    static let serverVersion = "0.1.0"

    static let instructions = """
        Audits and edits Xcode String Catalogs (.xcstrings).

        Every tool needs an absolute `projectRoot`; there is no working directory.

        Start with check_catalogs (translation coverage) or scan_sources (strings in \
        code that no catalog knows about). To fix missing translations, call \
        add_translations with an xclocsmith/v1 payload. Before importing a bundle from \
        a translator, call xcloc_check — it compares format specifiers, which Xcode's \
        own import does not.

        prune_catalogs deletes keys permanently and defaults to reporting only; keys \
        assembled at runtime cannot be seen from source, so review its list before \
        setting apply.
        """
}

// MARK: - JSON-RPC

struct RPCError: Error {
    let code: Int
    let message: String

    static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
    static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: -32601, message: "unknown method \"\(method)\"")
    }
    static let parseError = RPCError(code: -32700, message: "invalid JSON")
}

func send(_ value: JSONValue) {
    print(JSONWriter.line(value))
    fflush(stdout)
}

func respond(id: JSONValue, result: JSONValue) {
    send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
}

func respond(id: JSONValue, error: RPCError) {
    send(.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": .object(["code": .number("\(error.code)"), "message": .string(error.message)]),
    ]))
}

/// Diagnostics go to stderr: stdout carries protocol messages only, and one
/// stray line there breaks the session.
func log(_ message: String) {
    FileHandle.standardError.write(Data("xclocsmith-mcp: \(message)\n".utf8))
}

// MARK: - Dispatch

func handle(method: String, params: JSONValue) throws -> JSONValue {
    switch method {
    case "initialize":
        // Echo the client's version when we speak it, else offer ours.
        let requested = params["protocolVersion"]?.stringValue
        let version = requested == MCP.protocolVersion ? MCP.protocolVersion : MCP.protocolVersion
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(MCP.serverName),
                "title": .string("xclocSmith"),
                "version": .string(MCP.serverVersion),
            ]),
            "instructions": .string(MCP.instructions),
        ])

    case "ping":
        return .object([:])

    case "tools/list":
        return .object(["tools": .array(ToolRegistry.all.map(\.definition))])

    case "tools/call":
        guard let name = params["name"]?.stringValue else {
            throw RPCError.invalidParams("\"name\" is required")
        }
        guard let tool = ToolRegistry.tool(named: name) else {
            throw RPCError.methodNotFound(name)
        }
        let arguments = ToolRegistry.arguments(params)

        do {
            let result = try tool.handler(arguments)
            var fields: [String: JSONValue] = [
                "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
                "isError": .bool(result.isError),
            ]
            if let structured = result.structured {
                fields["structuredContent"] = structured
            }
            return .object(fields)
        } catch let error as SmithError {
            // A tool failing is a result, not a protocol error: the model should
            // see what went wrong and correct its next call.
            return .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(error.description),
                ])]),
                "isError": .bool(true),
            ])
        } catch {
            return .object([
                "content": .array([.object(["type": .string("text"), "text": .string("\(error)")])]),
                "isError": .bool(true),
            ])
        }

    default:
        throw RPCError.methodNotFound(method)
    }
}

// MARK: - Loop

log("ready on stdio (protocol \(MCP.protocolVersion), \(ToolRegistry.all.count) tools)")

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

    let message: JSONValue
    do {
        message = try JSONParser.parse(line)
    } catch {
        respond(id: .null, error: .parseError)
        continue
    }

    guard let method = message["method"]?.stringValue else { continue }
    let id = message["id"]
    let params = message["params"] ?? .object([:])

    // A notification has no id and takes no response.
    guard let id else {
        if method == "notifications/initialized" { log("client initialized") }
        continue
    }

    do {
        respond(id: id, result: try handle(method: method, params: params))
    } catch let error as RPCError {
        respond(id: id, error: error)
    } catch let error as SmithError {
        respond(id: id, error: .invalidParams(error.description))
    } catch {
        respond(id: id, error: RPCError(code: -32603, message: "\(error)"))
    }
}
