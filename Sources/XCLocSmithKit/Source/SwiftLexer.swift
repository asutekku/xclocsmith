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
    /// The key an interpolated literal would be extracted as, with `%@` standing
    /// in for each interpolation. Reporting the raw value instead shows `" ⸱ "`
    /// for `"\(a) ⸱ \(b)"`, which names nothing anyone can search for.
    public let formatKey: String?
}

/// The result of tokenising one Swift file.
public struct LexedSource: Sendable {
    /// The file's UTF-8, with comments and literal bodies blanked to spaces.
    /// Offsets therefore map 1:1 back to the original text's bytes.
    ///
    /// Bytes rather than `Character`s because every question asked of this is
    /// about ASCII punctuation, and a grapheme-cluster array costs four times
    /// the memory, a Unicode-aware pass to build, and a canonical-equivalence
    /// comparison every time it is read. Any byte below 0x80 is unambiguous in
    /// UTF-8, so a delimiter can never be confused with part of another
    /// character.
    public let bytes: [UInt8]
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
        let bytes = context.code
        return LexedSource(
            bytes: bytes,
            literals: context.literals.sorted { $0.start < $1.start },
            ignoredLines: context.ignoredLines,
            isFileIgnored: context.isFileIgnored,
            previewRanges: previewRanges(in: bytes)
        )
    }

    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D

    /// `#Preview { … }` bodies and `PreviewProvider` conformances. Sample data
    /// in previews is not shipped UI, so it is not a localization defect.
    static func previewRanges(in code: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for marker in ["#Preview".scanBytes, "PreviewProvider".scanBytes] {
            for start in ByteScan.occurrences(of: marker, in: code) {
                var index = start
                let limit = min(code.count, start + 300)
                while index < limit, code[index] != openBrace { index += 1 }
                guard index < limit, code[index] == openBrace else { continue }
                var depth = 0
                var end = index
                while end < code.count {
                    if code[end] == openBrace { depth += 1 }
                    if code[end] == closeBrace {
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
}

/// Matches the format specifier an interpolation segment could become.
let interpolationPlaceholderPattern =
    #"%(?:\d+\$)?[-+#0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGaAcCsS]"#

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let star = UInt8(ascii: "*")
private let hash = UInt8(ascii: "#")
private let space = UInt8(ascii: " ")
private let tab: UInt8 = 0x09
private let lineFeed: UInt8 = 0x0A
private let carriageReturn: UInt8 = 0x0D
private let openParen = UInt8(ascii: "(")
private let closeParen = UInt8(ascii: ")")
private let openBrace = UInt8(ascii: "{")
private let closeBrace = UInt8(ascii: "}")

private struct LexContext {
    let chars: [UInt8]
    var code: [UInt8]
    var literals: [SourceLiteral] = []
    var ignoredLines: Set<Int> = []
    var isFileIgnored = false

    private var index = 0
    private var line = 1

    init(text: String) {
        chars = Array(text.utf8)
        code = chars
    }

    private mutating func blank(_ range: Range<Int>) {
        guard range.lowerBound < range.upperBound else { return }
        for offset in range where !ByteScan.isNewline(code[offset]) { code[offset] = space }
    }

    /// The length of the line break at `offset`, or nil. `\r\n` is one break,
    /// so a file with Windows line endings still numbers its lines the way an
    /// editor does.
    private func newlineLength(at offset: Int) -> Int? {
        let byte = chars[offset]
        if byte == carriageReturn {
            return offset + 1 < chars.count && chars[offset + 1] == lineFeed ? 2 : 1
        }
        return ByteScan.isNewline(byte) ? 1 : nil
    }

    /// The pragma comments, matched without decoding the comment to a String —
    /// nearly every line comment in a project is neither.
    private static let ignoreFileMarkers = ["xclocsmith:ignore-file", "loccheck:ignore-file"].map(\.scanBytes)
    private static let ignoreMarkers = ["xclocsmith:ignore", "loccheck:ignore"].map(\.scanBytes)

    private func containsIgnoreFileMarker(_ comment: ArraySlice<UInt8>) -> Bool {
        Self.ignoreFileMarkers.contains { ByteScan.contains($0, in: chars, range: comment.startIndex..<comment.endIndex) }
    }

    private func containsIgnoreMarker(_ comment: ArraySlice<UInt8>) -> Bool {
        Self.ignoreMarkers.contains { ByteScan.contains($0, in: chars, range: comment.startIndex..<comment.endIndex) }
    }

    /// Marks where an interpolation sat while the template is assembled.
    static let interpolationSentinel: Character = "\u{0}"

    /// Turns the template into a regex matching the catalog keys this literal
    /// could produce.
    ///
    /// A literal `%` is written `%%` by Xcode's extractor — `"Battery at
    /// \(pct)%"` is stored as `"Battery at %lld%%"` — so the pattern has to
    /// double it too, or every such string reads as missing from the catalog.
    /// The extracted-key form: interpolations become `%@`, literal percents are
    /// doubled the way Xcode writes them.
    static func formatKey(from template: String) -> String {
        template
            .split(separator: interpolationSentinel, omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "%", with: "%%") }
            .joined(separator: "%@")
    }

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

            if let length = newlineLength(at: index) {
                line += 1
                index += length
                continue
            }

            if character == slash, index + 1 < count, chars[index + 1] == slash {
                var end = index
                while end < count, newlineLength(at: end) == nil { end += 1 }
                let comment = chars[index..<end]
                if containsIgnoreFileMarker(comment) {
                    isFileIgnored = true
                } else if containsIgnoreMarker(comment) {
                    ignoredLines.insert(line)
                }
                blank(index..<end)
                index = end
                continue
            }

            if character == slash, index + 1 < count, chars[index + 1] == star {
                index = skipBlockComment(from: index)
                continue
            }

            if character == hash {
                var hashes = 0
                var next = index
                while next < count, chars[next] == hash { hashes += 1; next += 1 }
                if next < count, chars[next] == quote {
                    index = scanLiteral(at: next, hashes: hashes, isNested: false)
                } else {
                    index = next
                }
                continue
            }

            if character == quote {
                index = scanLiteral(at: index, hashes: 0, isNested: false)
                continue
            }

            // Consume identifiers whole so a `#` or quote inside one cannot confuse us.
            if ByteScan.isIdentifier(character) {
                while index < count, ByteScan.isIdentifier(chars[index]) { index += 1 }
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
            if chars[end] == slash, end + 1 < count, chars[end + 1] == star {
                depth += 1
                end += 2
                continue
            }
            if chars[end] == star, end + 1 < count, chars[end + 1] == slash {
                depth -= 1
                end += 2
                if depth == 0 { break }
                continue
            }
            if let length = newlineLength(at: end) { line += 1; end += length; continue }
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
        let isMultiline = start + 2 < count && chars[start + 1] == quote && chars[start + 2] == quote
        let delimiterLength = isMultiline ? 3 : 1

        func hashesFollow(_ offset: Int) -> Bool {
            guard hashes > 0 else { return true }
            guard offset + hashes <= count else { return false }
            for step in 0..<hashes where chars[offset + step] != hash { return false }
            return true
        }

        func isEscape(_ offset: Int) -> Bool {
            chars[offset] == backslash && hashesFollow(offset + 1)
        }

        var cursor = start + delimiterLength
        var raw: [UInt8] = []
        // The template mirrors `raw` but keeps a sentinel where each
        // interpolation was, so multi-line indent stripping can be applied to
        // both before the regex is built.
        var template: [UInt8] = []
        var hasInterpolation = false
        var closed = false
        var end = count
        var contentEnd = count

        while cursor < count {
            let character = chars[cursor]

            if character == quote {
                if isMultiline {
                    if cursor + 2 < count, chars[cursor + 1] == quote, chars[cursor + 2] == quote,
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

            if let length = newlineLength(at: cursor) {
                guard isMultiline else { break }   // unterminated single-line literal
                line += 1
                // Normalised, the way one `Character` for `\r\n` was.
                raw.append(lineFeed)
                template.append(lineFeed)
                cursor += length
                continue
            }

            if isEscape(cursor) {
                let payload = cursor + 1 + hashes
                guard payload < count else { cursor = count; break }

                if chars[payload] == openParen {
                    hasInterpolation = true
                    template.append(0)
                    cursor = skipInterpolation(from: payload + 1)
                    continue
                }

                let (decoded, next) = decodeEscape(at: payload)
                raw.append(contentsOf: decoded)
                template.append(contentsOf: decoded)
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

        var value = String(decoding: raw, as: UTF8.self)
        var patternTemplate = String(decoding: template, as: UTF8.self)
        if isMultiline {
            let indent = closingIndent(before: contentEnd)
            value = Self.stripMultilineIndent(value, closingIndent: indent)
            patternTemplate = Self.stripMultilineIndent(patternTemplate, closingIndent: indent)
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
            formatPattern: hasInterpolation ? Self.formatPattern(from: patternTemplate) : nil,
            formatKey: hasInterpolation ? Self.formatKey(from: patternTemplate) : nil
        ))

        return end
    }

    /// Whitespace preceding the closing delimiter, in source order.
    private func closingIndent(before contentEnd: Int) -> String {
        var indent: [Character] = []
        var probe = contentEnd - 1
        while probe >= 0, chars[probe] == space || chars[probe] == tab {
            indent.append(chars[probe] == tab ? "\t" : " ")
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

            if let length = newlineLength(at: probe) { line += 1; probe += length; continue }
            if character == openParen { depth += 1; probe += 1; continue }
            if character == closeParen { depth -= 1; probe += 1; continue }

            if character == slash, probe + 1 < count, chars[probe + 1] == slash {
                while probe < count, newlineLength(at: probe) == nil { probe += 1 }
                continue
            }
            if character == slash, probe + 1 < count, chars[probe + 1] == star {
                probe = skipBlockComment(from: probe)
                continue
            }
            if character == quote {
                probe = scanLiteral(at: probe, hashes: 0, isNested: true)
                continue
            }
            if character == hash {
                var hashes = 0
                var next = probe
                while next < count, chars[next] == hash { hashes += 1; next += 1 }
                if next < count, chars[next] == quote {
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
    private func decodeEscape(at offset: Int) -> ([UInt8], Int) {
        let count = chars.count
        guard offset < count else { return ([], count) }
        switch chars[offset] {
        case UInt8(ascii: "n"): return ([lineFeed], offset + 1)
        case UInt8(ascii: "t"): return ([tab], offset + 1)
        case UInt8(ascii: "r"): return ([carriageReturn], offset + 1)
        case UInt8(ascii: "0"): return ([0], offset + 1)
        case backslash: return ([backslash], offset + 1)
        case quote: return ([quote], offset + 1)
        case UInt8(ascii: "'"): return ([UInt8(ascii: "'")], offset + 1)
        case UInt8(ascii: "u"):
            var cursor = offset + 1
            guard cursor < count, chars[cursor] == openBrace else { return ([], offset + 1) }
            cursor += 1
            var hex = ""
            while cursor < count, chars[cursor] != closeBrace {
                hex.append(Character(UnicodeScalar(chars[cursor])))
                cursor += 1
            }
            if cursor < count { cursor += 1 }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                return ([], cursor)
            }
            return (Array(String(Character(scalar)).utf8), cursor)
        default:
            // One byte, not one character. The continuation bytes of a
            // multi-byte payload are appended by the caller's loop, which
            // cannot mistake them for a delimiter — every byte it tests for is
            // ASCII, and no continuation byte is.
            return ([chars[offset]], offset + 1)
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
