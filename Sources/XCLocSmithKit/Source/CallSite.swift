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
    private let code: [Character]
    private var siteCache: [Int: CallSite] = [:]

    public init(code: [Character]) {
        self.code = code
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
            while probe >= 0, code[probe] == " " || code[probe] == "\t" || code[probe].isNewline { probe -= 1 }
        }
        skipWhitespace()
        guard probe >= 0, code[probe] == "=" else { return nil }
        // Not `==`, `!=`, `>=`, `<=`.
        guard probe - 1 >= 0, !"=!<>+-*/%".contains(code[probe - 1]) else { return nil }
        probe -= 1
        skipWhitespace()
        let end = probe
        while probe >= 0, code[probe].isLetter || code[probe].isNumber || code[probe] == "_" { probe -= 1 }
        guard end > probe else { return nil }
        // Only a member access is an assignment to a view's text. `let title =
        // "…"` is a local constant, and every Swift file is full of those.
        guard probe >= 0, code[probe] == "." else { return nil }
        return String(code[(probe + 1)...end])
    }

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
        String(code[range.clamped(to: 0..<code.count)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the argument contains nothing but this literal.
    private func argumentSpansOnly(literal: SourceLiteral, argument: CallArgument) -> Bool {
        let before = argument.range.lowerBound..<min(literal.contextStart, argument.range.upperBound)
        let after = min(literal.end, argument.range.upperBound)..<argument.range.upperBound
        return text(in: before).isEmpty && text(in: after).isEmpty
    }

    /// For `"Save".localized`, returns `localized`.
    ///
    /// Only a member accessed directly on the literal counts: `.localized(with:)`
    /// is still `localized`, but a newline before the dot would be a chained
    /// expression on something else.
    private func trailingMember(after literal: SourceLiteral) -> String? {
        var probe = literal.end
        while probe < code.count, code[probe] == " " || code[probe] == "\t" { probe += 1 }
        guard probe < code.count, code[probe] == "." else { return nil }
        probe += 1
        let start = probe
        while probe < code.count, code[probe].isLetter || code[probe].isNumber || code[probe] == "_" {
            probe += 1
        }
        guard probe > start else { return nil }
        return String(code[start..<probe])
    }

    private func isConcatenated(_ literal: SourceLiteral) -> Bool {
        var before = literal.contextStart - 1
        while before >= 0, code[before] == " " || code[before] == "\t" || code[before].isNewline { before -= 1 }
        if before >= 0, code[before] == "+" { return true }

        var after = literal.end
        while after < code.count, code[after] == " " || code[after] == "\t" || code[after].isNewline { after += 1 }
        return after < code.count && code[after] == "+"
    }

    /// Walks back to the `(` that opens the call containing `offset`.
    private func enclosingCallParen(before offset: Int) -> Int? {
        var depth = 0
        var probe = offset - 1
        while probe >= 0 {
            let character = code[probe]
            if character == ")" || character == "]" || character == "}" {
                depth += 1
            } else if character == "(" {
                if depth == 0 { return probe }
                depth -= 1
            } else if character == "[" || character == "{" {
                if depth == 0 { return nil }   // array or closure, not a call
                depth -= 1
            }
            probe -= 1
        }
        return nil
    }

    private func parseCallSite(openParen: Int) -> CallSite? {
        guard let (callee, isMethod) = calleeName(before: openParen) else { return nil }

        var arguments: [CallArgument] = []
        var depth = 0
        var cursor = openParen + 1
        var argumentStart = cursor

        while cursor < code.count {
            let character = code[cursor]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                if depth == 0, character == ")" {
                    if cursor > argumentStart {
                        arguments.append(makeArgument(argumentStart..<cursor))
                    }
                    return CallSite(callee: callee, isMethod: isMethod, openParen: openParen, arguments: arguments)
                }
                depth -= 1
            } else if character == ",", depth == 0 {
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
            while cursor < range.upperBound,
                  code[cursor] == " " || code[cursor] == "\t" || code[cursor].isNewline { cursor += 1 }
        }

        skipWhitespace()
        let identifierStart = cursor
        while cursor < range.upperBound,
              code[cursor].isLetter || code[cursor].isNumber || code[cursor] == "_" { cursor += 1 }
        let identifierEnd = cursor
        guard identifierEnd > identifierStart else { return CallArgument(label: nil, range: range) }

        skipWhitespace()
        guard cursor < range.upperBound, code[cursor] == ":" else {
            return CallArgument(label: nil, range: range)
        }
        // `::` does not occur in Swift, but a `?:` would already have failed above.
        let label = String(code[identifierStart..<identifierEnd])
        return CallArgument(label: label, range: (cursor + 1)..<range.upperBound)
    }

    private func calleeName(before openParen: Int) -> (String, Bool)? {
        let end = openParen - 1
        // Swift allows no space between a callee and its parenthesis, so anything
        // else here means this is not a call (`if (x)`, `return (a, b)`).
        guard end >= 0 else { return nil }
        var start = end
        while start >= 0, code[start].isLetter || code[start].isNumber || code[start] == "_" { start -= 1 }
        guard end > start else { return nil }
        let name = String(code[(start + 1)...end])
        let isMethod = start >= 0 && code[start] == "."
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
