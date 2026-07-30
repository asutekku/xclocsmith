import Foundation

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let column: Int
    public let reason: String

    public var description: String { "line \(line), column \(column): \(reason)" }
}

/// A strict JSON parser.
///
/// Strict on purpose: this tool rewrites files people cannot easily reconstruct,
/// so anything ambiguous is an error rather than a guess. In particular it
/// rejects duplicate keys (the classic bad-merge artifact in a `.xcstrings`,
/// where last-wins would silently discard a translation) and malformed numbers
/// (which a lenient parser would happily re-emit as still-invalid JSON).
public struct JSONParser {
    /// Deeper than any real catalog; guards the recursive descent against a
    /// hostile or corrupt file taking the process down with a stack overflow.
    public static let maximumDepth = 256

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    private init(_ data: Data) {
        bytes = Array(data)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(data)
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    // MARK: - Position reporting

    private func position(of offset: Int) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var cursor = 0
        while cursor < offset && cursor < bytes.count {
            if bytes[cursor] == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            cursor += 1
        }
        return (line, column)
    }

    private func error(_ reason: String, at offset: Int? = nil) -> JSONParseError {
        let (line, column) = position(of: offset ?? index)
        return JSONParseError(line: line, column: column, reason: reason)
    }

    // MARK: - Document

    private mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("unexpected trailing data") }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw error("expected \(literal)")
        }
        index += expected.count
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= Self.maximumDepth else {
            throw error("nesting deeper than \(Self.maximumDepth) levels")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1
        var fields: [String: JSONValue] = [:]

        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(fields)
        }

        while true {
            skipWhitespace()
            let keyOffset = index
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error("expected a quoted object key")
            }
            let key = try parseString()
            guard fields[key] == nil else {
                throw error("duplicate key \"\(key)\" — refusing to guess which value to keep", at: keyOffset)
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw error("expected ':' after object key")
            }
            index += 1
            skipWhitespace()
            fields[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(fields)
            default: throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []

        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }

        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            switch bytes[index] {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(items)
            default: throw error("expected ',' or ']'")
            }
        }
    }

    /// RFC 8259 grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
    private mutating func parseNumber() throws -> String {
        let start = index

        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        if peek() == UInt8(ascii: "-") { index += 1 }

        guard let first = peek(), isDigit(first) else { throw error("invalid number", at: start) }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        if peek() == UInt8(ascii: ".") {
            index += 1
            guard let byte = peek(), isDigit(byte) else { throw error("invalid number: expected a digit after '.'", at: start) }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            index += 1
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
            guard let byte = peek(), isDigit(byte) else { throw error("invalid number: expected a digit in the exponent", at: start) }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var scalars: [Unicode.Scalar] = []

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: "\"") {
                index += 1
                var result = ""
                result.unicodeScalars.append(contentsOf: scalars)
                return result
            }

            if byte < 0x20 {
                throw error("unescaped control character in string")
            }

            if byte != UInt8(ascii: "\\") {
                // Copy the UTF-8 sequence verbatim; invalid bytes are an error
                // rather than something to replace with U+FFFD behind the
                // author's back.
                let length = utf8SequenceLength(byte)
                guard length > 0, index + length <= bytes.count,
                      let scalar = decodeUTF8(at: index, length: length) else {
                    throw error("invalid UTF-8 byte sequence in string")
                }
                scalars.append(scalar)
                index += length
                continue
            }

            index += 1
            guard index < bytes.count else { throw error("unterminated escape sequence") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append(Unicode.Scalar(0x08)!)
            case UInt8(ascii: "f"): scalars.append(Unicode.Scalar(0x0C)!)
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"): scalars.append(try parseUnicodeEscape())
            default: throw error("invalid escape sequence '\\\(Character(Unicode.Scalar(escape)))'")
            }
        }

        throw error("unterminated string", at: start)
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let value = try parseHexQuad()

        if value >= 0xD800 && value <= 0xDBFF {
            guard index + 1 < bytes.count,
                  bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u") else {
                throw error("high surrogate \\u\(String(value, radix: 16)) is not followed by a low surrogate")
            }
            index += 2
            let low = try parseHexQuad()
            guard low >= 0xDC00 && low <= 0xDFFF else {
                throw error("expected a low surrogate, found \\u\(String(low, radix: 16))")
            }
            let combined = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { throw error("invalid surrogate pair") }
            return scalar
        }

        guard value < 0xD800 || value > 0xDFFF else {
            throw error("lone low surrogate \\u\(String(value, radix: 16))")
        }
        guard let scalar = Unicode.Scalar(value) else { throw error("invalid \\u escape") }
        return scalar
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw error("invalid hex digit in \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private func utf8SequenceLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0
        }
    }

    private func decodeUTF8(at offset: Int, length: Int) -> Unicode.Scalar? {
        var decoder = UTF8()
        var iterator = bytes[offset..<(offset + length)].makeIterator()
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar): return scalar
        case .emptyInput, .error: return nil
        }
    }
}
