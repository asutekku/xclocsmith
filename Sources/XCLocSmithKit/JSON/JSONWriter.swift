import Foundation

/// Serialises a `JSONValue` back to text.
///
/// `.xcode` reproduces exactly what Xcode writes into a `.xcstrings`: two-space
/// indent, a space either side of the key separator, escaped forward slashes,
/// expanded empty containers, and keys sorted by Unicode order. Getting this
/// byte-exact matters more than it sounds — a tool that reformats the file turns
/// every one-key edit into a whole-file diff and a merge conflict for the rest
/// of the team.
///
/// Foundation's `JSONSerialization.WritingOptions.sortedKeys` cannot be used
/// here: it sorts with a localized comparison, so it reorders the entire
/// catalog relative to Xcode's plain Unicode ordering.
public enum JSONWriter {
    public enum Style: Sendable {
        /// Byte-compatible with Xcode's own writer. Use for `.xcstrings`.
        case xcode
        /// Conventional JSON for files this tool owns (config, reports).
        case plain
        /// One line, no whitespace. Required by newline-delimited transports.
        case compact
    }

    public static func text(_ value: JSONValue, style: Style = .xcode) -> String {
        var output = ""
        write(value, indent: 0, style: style, into: &output)
        output += "\n"
        return output
    }

    /// One line, no trailing newline — for newline-delimited transports.
    public static func line(_ value: JSONValue) -> String {
        var output = ""
        writeCompact(value, into: &output)
        return output
    }

    private static func write(_ value: JSONValue, indent: Int, style: Style, into output: inout String) {
        if style == .compact {
            writeCompact(value, into: &output)
            return
        }
        let pad = String(repeating: " ", count: indent * 2)
        let inner = String(repeating: " ", count: (indent + 1) * 2)
        let separator = style == .xcode ? " : " : ": "

        switch value {
        case .string(let string):
            output += "\"\(escape(string, style: style))\""

        case .number(let raw):
            output += raw

        case .bool(let flag):
            output += flag ? "true" : "false"

        case .null:
            output += "null"

        case .array(let items):
            guard !items.isEmpty else {
                output += style == .xcode ? "[\n\n\(pad)]" : "[]"
                return
            }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += inner
                write(item, indent: indent + 1, style: style, into: &output)
                output += offset == items.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)]"

        case .object(let fields):
            guard !fields.isEmpty else {
                output += style == .xcode ? "{\n\n\(pad)}" : "{}"
                return
            }
            let keys = fields.keys.sorted()
            output += "{\n"
            for (offset, key) in keys.enumerated() {
                output += "\(inner)\"\(escape(key, style: style))\"\(separator)"
                if let field = fields[key] {
                    write(field, indent: indent + 1, style: style, into: &output)
                }
                output += offset == keys.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)}"
        }
    }

    private static func writeCompact(_ value: JSONValue, into output: inout String) {
        switch value {
        case .string(let string): output += "\"\(escape(string, style: .compact))\""
        case .number(let raw): output += raw
        case .bool(let flag): output += flag ? "true" : "false"
        case .null: output += "null"
        case .array(let items):
            output += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { output += "," }
                writeCompact(item, into: &output)
            }
            output += "]"
        case .object(let fields):
            output += "{"
            for (offset, key) in fields.keys.sorted().enumerated() {
                if offset > 0 { output += "," }
                output += "\"\(escape(key, style: .compact))\":"
                if let field = fields[key] { writeCompact(field, into: &output) }
            }
            output += "}"
        }
    }

    private static func escape(_ string: String, style: Style) -> String {
        var output = ""
        output.reserveCapacity(string.count + 8)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "/": output += style == .xcode ? "\\/" : "/"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}
