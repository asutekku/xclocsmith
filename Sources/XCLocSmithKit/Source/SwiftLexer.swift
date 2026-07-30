import Foundation

/// A string literal found in Swift source, with its value already unescaped.
public struct SourceLiteral: Equatable, Sendable {
    /// The value as it would appear as a catalog key.
    public let value: String
    public let line: Int
    /// Offset of the opening quote in the character array.
    public let start: Int
    /// Offset of the leading `#` of a raw string, else `start`.
    public let contextStart: Int
    /// Offset just past the closing delimiter.
    public let end: Int
    public let hasInterpolation: Bool
    public let isMultiline: Bool
    /// True when this literal sits inside another literal's interpolation, so
    /// it is a value rather than a catalog key.
    public let isNested: Bool
    /// Regex source matching the catalog keys this interpolation could produce
    /// (`"Hello \(name)"` → `Hello %@` or `Hello %lld`).
    public let formatPattern: String?
}

/// The result of tokenising one Swift file.
public struct LexedSource: Sendable {
    /// Same length as the input, with comments and literal bodies blanked to
    /// spaces. Offsets therefore map 1:1 back to the original text.
    public let code: [Character]
    public let literals: [SourceLiteral]
    public let ignoredLines: Set<Int>
    public let isFileIgnored: Bool
    /// Ranges covered by `#Preview` / `PreviewProvider` bodies.
    public let previewRanges: [Range<Int>]

    public func isInsidePreview(_ literal: SourceLiteral) -> Bool {
        previewRanges.contains { $0.contains(literal.contextStart) }
    }
}

/// Tokenises Swift far enough to know what is code, what is a comment, and what
/// is a string literal.
///
/// Regex-per-line cannot do this job: it misses multi-line literals, treats
/// escaped quotes as terminators, matches inside comments, and cannot tell
/// `#"\(raw)"#` from interpolation. Every one of those produced a wrong answer
/// in the predecessor of this tool, and one of them deleted live catalog keys.
public enum SwiftLexer {
    public static func lex(_ text: String) -> LexedSource {
        var context = LexContext(text: text)
        context.run()
        return LexedSource(
            code: context.code,
            literals: context.literals.sorted { $0.start < $1.start },
            ignoredLines: context.ignoredLines,
            isFileIgnored: context.isFileIgnored,
            previewRanges: previewRanges(in: context.code)
        )
    }

    /// `#Preview { … }` bodies and `PreviewProvider` conformances. Sample data
    /// in previews is not shipped UI, so it is not a localization defect.
    static func previewRanges(in code: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for marker in [Array("#Preview"), Array("PreviewProvider")] {
            for start in occurrences(of: marker, in: code) {
                var index = start
                let limit = min(code.count, start + 300)
                while index < limit, code[index] != "{" { index += 1 }
                guard index < limit, code[index] == "{" else { continue }
                var depth = 0
                var end = index
                while end < code.count {
                    if code[end] == "{" { depth += 1 }
                    if code[end] == "}" {
                        depth -= 1
                        if depth == 0 { end += 1; break }
                    }
                    end += 1
                }
                ranges.append(start..<min(end, code.count))
            }
        }
        return ranges
    }

    static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        for index in 0...(haystack.count - needle.count) where haystack[index] == needle[0] {
            var offset = 1
            while offset < needle.count, haystack[index + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { found.append(index) }
        }
        return found
    }
}

/// Matches the format specifier an interpolation segment could become.
let interpolationPlaceholderPattern =
    #"%(?:\d+\$)?[-+#0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGaAcCsS]"#

private struct LexContext {
    let chars: [Character]
    var code: [Character]
    var literals: [SourceLiteral] = []
    var ignoredLines: Set<Int> = []
    var isFileIgnored = false

    private var index = 0
    private var line = 1

    init(text: String) {
        chars = Array(text)
        code = chars
    }

    private mutating func blank(_ range: Range<Int>) {
        guard range.lowerBound < range.upperBound else { return }
        for offset in range where !code[offset].isNewline { code[offset] = " " }
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Marks where an interpolation sat while the template is assembled.
    static let interpolationSentinel: Character = "\u{0}"

    /// Turns the template into a regex matching the catalog keys this literal
    /// could produce.
    ///
    /// A literal `%` is written `%%` by Xcode's extractor — `"Battery at
    /// \(pct)%"` is stored as `"Battery at %lld%%"` — so the pattern has to
    /// double it too, or every such string reads as missing from the catalog.
    static func formatPattern(from template: String) -> String {
        template
            .split(separator: interpolationSentinel, omittingEmptySubsequences: false)
            .map { segment in
                NSRegularExpression.escapedPattern(
                    for: segment.replacingOccurrences(of: "%", with: "%%")
                )
            }
            .joined(separator: interpolationPlaceholderPattern)
    }

    mutating func run() {
        let count = chars.count
        while index < count {
            let character = chars[index]

            if character.isNewline {
                line += 1
                index += 1
                continue
            }

            if character == "/", index + 1 < count, chars[index + 1] == "/" {
                var end = index
                while end < count, !chars[end].isNewline { end += 1 }
                let comment = String(chars[index..<end])
                if comment.contains("xclocsmith:ignore-file") || comment.contains("loccheck:ignore-file") {
                    isFileIgnored = true
                } else if comment.contains("xclocsmith:ignore") || comment.contains("loccheck:ignore") {
                    ignoredLines.insert(line)
                }
                blank(index..<end)
                index = end
                continue
            }

            if character == "/", index + 1 < count, chars[index + 1] == "*" {
                index = skipBlockComment(from: index)
                continue
            }

            if character == "#" {
                var hashes = 0
                var next = index
                while next < count, chars[next] == "#" { hashes += 1; next += 1 }
                if next < count, chars[next] == "\"" {
                    index = scanLiteral(at: next, hashes: hashes, isNested: false)
                } else {
                    index = next
                }
                continue
            }

            if character == "\"" {
                index = scanLiteral(at: index, hashes: 0, isNested: false)
                continue
            }

            // Consume identifiers whole so a `#` or quote inside one cannot confuse us.
            if isIdentifierCharacter(character) {
                while index < count, isIdentifierCharacter(chars[index]) { index += 1 }
                continue
            }

            index += 1
        }
    }

    /// Returns the offset just past the comment. Handles nesting, which Swift allows.
    private mutating func skipBlockComment(from start: Int) -> Int {
        let count = chars.count
        var end = start
        var depth = 0
        while end < count {
            if chars[end] == "/", end + 1 < count, chars[end + 1] == "*" {
                depth += 1
                end += 2
                continue
            }
            if chars[end] == "*", end + 1 < count, chars[end + 1] == "/" {
                depth -= 1
                end += 2
                if depth == 0 { break }
                continue
            }
            if chars[end].isNewline { line += 1 }
            end += 1
        }
        let stop = min(end, count)
        blank(start..<stop)
        return stop
    }

    /// Reads the literal whose opening quote is at `start`; returns the offset
    /// just past it. Recurses for literals nested in interpolations.
    private mutating func scanLiteral(at start: Int, hashes: Int, isNested: Bool) -> Int {
        let count = chars.count
        let startLine = line
        let isMultiline = start + 2 < count && chars[start + 1] == "\"" && chars[start + 2] == "\""
        let delimiterLength = isMultiline ? 3 : 1

        func hashesFollow(_ offset: Int) -> Bool {
            guard hashes > 0 else { return true }
            guard offset + hashes <= count else { return false }
            for step in 0..<hashes where chars[offset + step] != "#" { return false }
            return true
        }

        func isEscape(_ offset: Int) -> Bool {
            chars[offset] == "\\" && hashesFollow(offset + 1)
        }

        var cursor = start + delimiterLength
        var raw = ""
        // The template mirrors `raw` but keeps a sentinel where each
        // interpolation was, so multi-line indent stripping can be applied to
        // both before the regex is built.
        var template = ""
        var hasInterpolation = false
        var closed = false
        var end = count
        var contentEnd = count

        while cursor < count {
            let character = chars[cursor]

            if character == "\"" {
                if isMultiline {
                    if cursor + 2 < count, chars[cursor + 1] == "\"", chars[cursor + 2] == "\"",
                       hashesFollow(cursor + 3) {
                        contentEnd = cursor
                        end = cursor + 3 + hashes
                        closed = true
                        break
                    }
                } else if hashesFollow(cursor + 1) {
                    contentEnd = cursor
                    end = cursor + 1 + hashes
                    closed = true
                    break
                }
                raw.append(character)
                template.append(character)
                cursor += 1
                continue
            }

            if character.isNewline {
                guard isMultiline else { break }   // unterminated single-line literal
                line += 1
                raw.append("\n")
                template.append("\n")
                cursor += 1
                continue
            }

            if isEscape(cursor) {
                let payload = cursor + 1 + hashes
                guard payload < count else { cursor = count; break }

                if chars[payload] == "(" {
                    hasInterpolation = true
                    template.append(Self.interpolationSentinel)
                    cursor = skipInterpolation(from: payload + 1)
                    continue
                }

                let (decoded, next) = decodeEscape(at: payload)
                raw += decoded
                template += decoded
                cursor = next
                continue
            }

            raw.append(character)
            template.append(character)
            cursor += 1
        }

        if !closed {
            end = min(cursor, count)
            contentEnd = end
        }

        var value = raw
        var patternTemplate = template
        if isMultiline {
            let indent = closingIndent(before: contentEnd)
            value = Self.stripMultilineIndent(raw, closingIndent: indent)
            patternTemplate = Self.stripMultilineIndent(template, closingIndent: indent)
        }

        blank((start + delimiterLength)..<max(start + delimiterLength, contentEnd))

        literals.append(SourceLiteral(
            value: value,
            line: startLine,
            start: start,
            contextStart: start - hashes,
            end: end,
            hasInterpolation: hasInterpolation,
            isMultiline: isMultiline,
            isNested: isNested,
            formatPattern: hasInterpolation ? Self.formatPattern(from: patternTemplate) : nil
        ))

        return end
    }

    /// Whitespace preceding the closing delimiter, in source order.
    private func closingIndent(before contentEnd: Int) -> String {
        var indent: [Character] = []
        var probe = contentEnd - 1
        while probe >= 0, chars[probe] == " " || chars[probe] == "\t" {
            indent.append(chars[probe])
            probe -= 1
        }
        // Collected walking backwards, so reverse it — otherwise a mixed
        // space+tab indent comes out transposed, the prefix never matches, and
        // the literal keeps whitespace that is not part of its value.
        return String(indent.reversed())
    }

    static func stripMultilineIndent(_ raw: String, closingIndent: String) -> String {
        var lines = splitLines(raw)
        if !lines.isEmpty { lines.removeFirst() }   // newline after the opening delimiter
        if !lines.isEmpty { lines.removeLast() }    // indentation before the closing delimiter
        return lines
            .map { $0.hasPrefix(closingIndent) ? String($0.dropFirst(closingIndent.count)) : $0 }
            .joined(separator: "\n")
    }

    /// Skips a `\( … )` interpolation, tracking nested parens, strings and
    /// comments. Nested literals are recorded as references but never as keys.
    private mutating func skipInterpolation(from start: Int) -> Int {
        let count = chars.count
        var depth = 1
        var probe = start

        while probe < count, depth > 0 {
            let character = chars[probe]

            if character.isNewline { line += 1; probe += 1; continue }
            if character == "(" { depth += 1; probe += 1; continue }
            if character == ")" { depth -= 1; probe += 1; continue }

            if character == "/", probe + 1 < count, chars[probe + 1] == "/" {
                while probe < count, !chars[probe].isNewline { probe += 1 }
                continue
            }
            if character == "/", probe + 1 < count, chars[probe + 1] == "*" {
                probe = skipBlockComment(from: probe)
                continue
            }
            if character == "\"" {
                probe = scanLiteral(at: probe, hashes: 0, isNested: true)
                continue
            }
            if character == "#" {
                var hashes = 0
                var next = probe
                while next < count, chars[next] == "#" { hashes += 1; next += 1 }
                if next < count, chars[next] == "\"" {
                    probe = scanLiteral(at: next, hashes: hashes, isNested: true)
                } else {
                    probe = next
                }
                continue
            }
            probe += 1
        }
        return probe
    }

    /// Decodes the escape whose payload starts at `offset`.
    private func decodeEscape(at offset: Int) -> (String, Int) {
        let count = chars.count
        guard offset < count else { return ("", count) }
        switch chars[offset] {
        case "n": return ("\n", offset + 1)
        case "t": return ("\t", offset + 1)
        case "r": return ("\r", offset + 1)
        case "0": return ("\0", offset + 1)
        case "\\": return ("\\", offset + 1)
        case "\"": return ("\"", offset + 1)
        case "'": return ("'", offset + 1)
        case "u":
            var cursor = offset + 1
            guard cursor < count, chars[cursor] == "{" else { return ("", offset + 1) }
            cursor += 1
            var hex = ""
            while cursor < count, chars[cursor] != "}" {
                hex.append(chars[cursor])
                cursor += 1
            }
            if cursor < count { cursor += 1 }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                return ("", cursor)
            }
            return (String(Character(scalar)), cursor)
        default:
            return (String(chars[offset]), offset + 1)
        }
    }
}

/// Splits on any line break, keeping empty lines so indices map to line numbers.
/// `components(separatedBy: "\n")` misses CRLF, which Swift stores as a single
/// `Character` that is not equal to `"\n"`.
public func splitLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
        if character.isNewline {
            lines.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    lines.append(current)
    return lines
}
