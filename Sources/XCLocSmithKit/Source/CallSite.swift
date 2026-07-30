import Foundation

public struct CallArgument: Equatable, Sendable {
    public let label: String?
    public let range: Range<Int>
}

/// A parsed call `callee(arg, label: arg, …)`.
public struct CallSite: Equatable, Sendable {
    public let callee: String
    public let isMethod: Bool
    public let openParen: Int
    public let arguments: [CallArgument]
}

/// Where a literal sits inside a call.
public struct LiteralContext: Equatable, Sendable {
    public let callee: String?
    public let isMethod: Bool
    /// Zero-based index among the call's arguments.
    public let argumentIndex: Int?
    public let label: String?
    /// False when the literal is only part of the argument — a branch of a
    /// ternary, an operand of `??`, an interpolation segment. Such a literal is
    /// still user-visible, which is precisely what a backwards-walking parser
    /// gets wrong.
    public let isEntireArgument: Bool
    /// Value of a sibling `tableName:` / `table:` argument, when it is a literal.
    public let tableName: String?
    /// A sibling table argument exists but is computed, so we cannot know the table.
    public let tableIsDynamic: Bool
    /// Text of a sibling `bundle:` argument, e.g. `.module`.
    public let bundle: String?
    /// The literal is an operand of `+`, which defeats catalog lookup.
    public let isConcatenated: Bool
    /// For `label.text = "Hi"`, the property being assigned.
    public let assignmentTarget: String?
    /// The member accessed directly on the literal: `"Save".localized` gives
    /// "localized". Projects define this extension constantly — it is the whole
    /// localization API in HSTracker (316 call sites) and Nimble Commander —
    /// and it is invisible to a parser that only looks at enclosing calls.
    public let trailingMember: String?

    static let none = LiteralContext(
        callee: nil, isMethod: false, argumentIndex: nil, label: nil,
        isEntireArgument: false, tableName: nil, tableIsDynamic: false,
        bundle: nil, isConcatenated: false, assignmentTarget: nil,
        trailingMember: nil
    )
}

/// Resolves each literal to its enclosing call by parsing the argument list
/// forward from the opening parenthesis.
public struct CallSiteAnalyzer {
    private let bytes: [UInt8]
    private var siteCache: [Int: CallSite] = [:]

    private static let openParenByte: UInt8 = 0x28
    private static let closeParenByte: UInt8 = 0x29
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let comma: UInt8 = 0x2C
    private static let colon: UInt8 = 0x3A
    private static let equals: UInt8 = 0x3D
    private static let dot: UInt8 = 0x2E
    private static let plus: UInt8 = 0x2B

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.enclosing = Self.openerTable(bytes)
    }

    /// The text of a byte range. Every range handed here starts and ends on an
    /// ASCII delimiter or an identifier boundary, so it is UTF-8 aligned.
    private func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    public mutating func context(for literal: SourceLiteral) -> LiteralContext {
        guard let openParen = enclosingCallParen(before: literal.contextStart) else {
            return LiteralContext(
                callee: nil, isMethod: false, argumentIndex: nil, label: nil,
                isEntireArgument: false, tableName: nil, tableIsDynamic: false,
                bundle: nil, isConcatenated: isConcatenated(literal),
                assignmentTarget: assignmentTarget(before: literal),
                trailingMember: trailingMember(after: literal)
            )
        }

        let site: CallSite
        if let cached = siteCache[openParen] {
            site = cached
        } else {
            guard let parsed = parseCallSite(openParen: openParen) else { return .none }
            siteCache[openParen] = parsed
            site = parsed
        }

        var argumentIndex: Int?
        var label: String?
        var isEntireArgument = false
        for (index, argument) in site.arguments.enumerated()
        where argument.range.contains(literal.contextStart) {
            argumentIndex = index
            label = argument.label
            isEntireArgument = argumentSpansOnly(literal: literal, argument: argument)
            break
        }

        var tableName: String?
        var tableIsDynamic = false
        var bundle: String?
        for argument in site.arguments {
            guard let argumentLabel = argument.label else { continue }
            switch argumentLabel {
            case "tableName", "table":
                if let value = literalValue(in: argument.range) {
                    tableName = value
                } else {
                    tableIsDynamic = true
                }
            case "bundle":
                bundle = text(in: argument.range)
            default:
                break
            }
        }

        return LiteralContext(
            callee: site.callee,
            isMethod: site.isMethod,
            argumentIndex: argumentIndex,
            label: label,
            isEntireArgument: isEntireArgument,
            tableName: tableName,
            tableIsDynamic: tableIsDynamic,
            bundle: bundle,
            isConcatenated: isConcatenated(literal),
            assignmentTarget: assignmentTarget(before: literal),
            trailingMember: trailingMember(after: literal)
        )
    }

    /// For `someLabel.text = "Hi"`, returns `text`.
    private func assignmentTarget(before literal: SourceLiteral) -> String? {
        var probe = literal.contextStart - 1
        func skipWhitespace() {
            while probe >= 0, ByteScan.isBlank(bytes[probe]) { probe -= 1 }
        }
        skipWhitespace()
        guard probe >= 0, bytes[probe] == Self.equals else { return nil }
        // Not `==`, `!=`, `>=`, `<=`.
        guard probe - 1 >= 0, !Self.comparisonPrefixes.contains(bytes[probe - 1]) else { return nil }
        probe -= 1
        skipWhitespace()
        let end = probe
        while probe >= 0, ByteScan.isIdentifier(bytes[probe]) { probe -= 1 }
        guard end > probe else { return nil }
        // Only a member access is an assignment to a view's text. `let title =
        // "…"` is a local constant, and every Swift file is full of those.
        guard probe >= 0, bytes[probe] == Self.dot else { return nil }
        return string((probe + 1)..<(end + 1))
    }

    /// `=!<>+-*/%` — an `=` preceded by one of these is a comparison or a
    /// compound assignment, not a plain assignment.
    private static let comparisonPrefixes: Set<UInt8> = Set("=!<>+-*/%".scanBytes)

    /// Literals recorded by the lexer, needed to read sibling arguments such as
    /// `tableName: "Errors"` whose bodies are blanked in `code`.
    public var literalsByStart: [Int: SourceLiteral] = [:]

    /// The literal in this argument, or `nil` when there is none — or more than
    /// one, as in `tableName: flag ? "A" : "B"`, where the table is not
    /// statically knowable. Dictionary order is not iteration order, so the
    /// candidates are sorted before choosing.
    private func literalValue(in range: Range<Int>) -> String? {
        let inside = literalsByStart
            .filter { range.contains($0.key) }
            .sorted { $0.key < $1.key }
        guard inside.count == 1 else { return nil }
        return inside.first?.value.value
    }

    private func text(in range: Range<Int>) -> String {
        string(range.clamped(to: 0..<bytes.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the argument contains nothing but this literal.
    private func argumentSpansOnly(literal: SourceLiteral, argument: CallArgument) -> Bool {
        let before = argument.range.lowerBound..<min(literal.contextStart, argument.range.upperBound)
        let after = min(literal.end, argument.range.upperBound)..<argument.range.upperBound
        return isBlank(before) && isBlank(after)
    }

    /// Whether the range holds nothing but whitespace — what asking whether the
    /// trimmed text is empty was doing, without building the string.
    private func isBlank(_ range: Range<Int>) -> Bool {
        let clamped = range.clamped(to: 0..<bytes.count)
        for offset in clamped where !ByteScan.isBlank(bytes[offset]) { return false }
        return true
    }

    /// For `"Save".localized`, returns `localized`.
    ///
    /// Only a member accessed directly on the literal counts: `.localized(with:)`
    /// is still `localized`, but a newline before the dot would be a chained
    /// expression on something else.
    private func trailingMember(after literal: SourceLiteral) -> String? {
        var probe = literal.end
        while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
        guard probe < bytes.count, bytes[probe] == Self.dot else { return nil }
        probe += 1
        let start = probe
        while probe < bytes.count, ByteScan.isIdentifier(bytes[probe]) { probe += 1 }
        guard probe > start else { return nil }
        return string(start..<probe)
    }

    private func isConcatenated(_ literal: SourceLiteral) -> Bool {
        var before = literal.contextStart - 1
        while before >= 0, ByteScan.isBlank(bytes[before]) { before -= 1 }
        if before >= 0, bytes[before] == Self.plus { return true }

        var after = literal.end
        while after < bytes.count, ByteScan.isBlank(bytes[after]) { after += 1 }
        return after < bytes.count && bytes[after] == Self.plus
    }

    /// The `(` that opens the call containing `offset`, from the table built in
    /// `init`.
    ///
    /// Walking backwards from each literal to find it was the single most
    /// expensive thing `scan` did: quadratic in a file with many literals, and
    /// paid again for every one of them. The same answer for every offset in
    /// the file falls out of one forward pass with a stack of open delimiters,
    /// because "nearest unmatched opener before here" is what both compute.
    private func enclosingCallParen(before offset: Int) -> Int? {
        guard offset >= 0, offset < enclosing.count else { return nil }
        let opener = Int(enclosing[offset])
        guard opener >= 0, bytes[opener] == Self.openParenByte else { return nil }
        return opener
    }

    /// `enclosing[i]` is the position of the innermost delimiter still open
    /// just before offset `i`, or -1. Int32 because a source file that needs
    /// more than two billion characters is not one this tool will be asked
    /// about, and half the memory keeps it in cache.
    private let enclosing: [Int32]

    private static func openerTable(_ bytes: [UInt8]) -> [Int32] {
        var table = [Int32](repeating: -1, count: bytes.count + 1)
        var stack: [Int32] = []
        stack.reserveCapacity(64)
        table.withUnsafeMutableBufferPointer { slots in
            bytes.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    switch source[index] {
                    case openParenByte, openBracket, openBrace:
                        stack.append(Int32(index))
                    case closeParenByte, closeBracket, closeBrace:
                        if !stack.isEmpty { stack.removeLast() }
                    default:
                        break
                    }
                    slots[index + 1] = stack.last ?? -1
                }
            }
        }
        return table
    }

    private func parseCallSite(openParen: Int) -> CallSite? {
        guard let (callee, isMethod) = calleeName(before: openParen) else { return nil }

        var arguments: [CallArgument] = []
        var depth = 0
        var cursor = openParen + 1
        var argumentStart = cursor

        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == Self.openParenByte || byte == Self.openBracket || byte == Self.openBrace {
                depth += 1
            } else if byte == Self.closeParenByte || byte == Self.closeBracket || byte == Self.closeBrace {
                if depth == 0, byte == Self.closeParenByte {
                    if cursor > argumentStart {
                        arguments.append(makeArgument(argumentStart..<cursor))
                    }
                    return CallSite(callee: callee, isMethod: isMethod, openParen: openParen, arguments: arguments)
                }
                depth -= 1
            } else if byte == Self.comma, depth == 0 {
                arguments.append(makeArgument(argumentStart..<cursor))
                argumentStart = cursor + 1
            }
            cursor += 1
        }
        return CallSite(callee: callee, isMethod: isMethod, openParen: openParen, arguments: arguments)
    }

    /// Detects a leading `label:`. A ternary's colon comes after an expression,
    /// never immediately after the argument's first identifier, so it cannot be
    /// mistaken for a label.
    private func makeArgument(_ range: Range<Int>) -> CallArgument {
        var cursor = range.lowerBound
        func skipWhitespace() {
            while cursor < range.upperBound, ByteScan.isBlank(bytes[cursor]) { cursor += 1 }
        }

        skipWhitespace()
        let identifierStart = cursor
        while cursor < range.upperBound, ByteScan.isIdentifier(bytes[cursor]) { cursor += 1 }
        let identifierEnd = cursor
        guard identifierEnd > identifierStart else { return CallArgument(label: nil, range: range) }

        skipWhitespace()
        guard cursor < range.upperBound, bytes[cursor] == Self.colon else {
            return CallArgument(label: nil, range: range)
        }
        // `::` does not occur in Swift, but a `?:` would already have failed above.
        let label = string(identifierStart..<identifierEnd)
        return CallArgument(label: label, range: (cursor + 1)..<range.upperBound)
    }

    private func calleeName(before openParen: Int) -> (String, Bool)? {
        let end = openParen - 1
        // Swift allows no space between a callee and its parenthesis, so anything
        // else here means this is not a call (`if (x)`, `return (a, b)`).
        guard end >= 0 else { return nil }
        var start = end
        while start >= 0, ByteScan.isIdentifier(bytes[start]) { start -= 1 }
        guard end > start else { return nil }
        let name = string((start + 1)..<(end + 1))
        let isMethod = start >= 0 && bytes[start] == Self.dot
        return (name, isMethod)
    }
}

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        let lower = Swift.max(lowerBound, limits.lowerBound)
        let upper = Swift.min(upperBound, limits.upperBound)
        return lower < upper ? lower..<upper : lower..<lower
    }
}
