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
    }

    public static func text(_ value: JSONValue, style: Style = .xcode) -> String {
        var output = ""
        write(value, indent: 0, style: style, into: &output)
        output += "\n"
        return output
    }

    private static func write(_ value: JSONValue, indent: Int, style: Style, into output: inout String) {
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
