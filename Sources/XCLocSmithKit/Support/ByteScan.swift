import Foundation

/// Byte-level views and searches over source text.
///
/// Every question the source parsers ask — is this a `(`, a comma, an
/// identifier character — is a question about ASCII punctuation. Asking it of a
/// `Character` goes through Unicode canonical equivalence:
/// `_stringCompareWithSmolCheck` was the single hottest symbol in the profile of
/// `scan`, and `[Character].contains("import XCTest")` runs a generic
/// grapheme-by-grapheme searcher. Both become integer work here.
public enum ByteScan {
    /// Stands in for any character that is not a single ASCII scalar. It is
    /// never equal to a delimiter, and the parsers treat it as an identifier
    /// character — which is what `Character.isLetter` reported for it.
    public static let nonASCII: UInt8 = 0x80

    /// One byte per element of `code`, so offsets stay interchangeable with the
    /// `[Character]` array the values are still read from.
    ///
    /// `Character.asciiValue` already reports a CR-LF pair as `\n`, so a file
    /// with Windows line endings — one `Character`, two scalars — is not
    /// mistaken for non-ASCII.
    public static func bytes(of code: [Character]) -> [UInt8] {
        var result = [UInt8](repeating: nonASCII, count: code.count)
        result.withUnsafeMutableBufferPointer { buffer in
            for index in code.indices {
                let character = code[index]
                if let ascii = character.asciiValue {
                    buffer[index] = ascii
                } else if character.isNewline {
                    buffer[index] = 0x0A
                } else if character.isWhitespace {
                    // A non-breaking or ideographic space still has to trim
                    // away, since the parsers ask whether a span is blank.
                    buffer[index] = 0x20
                }
            }
        }
        return result
    }

    /// Literal substring search, skipping ahead on the first byte.
    public static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        firstIndex(of: needle, in: haystack, from: 0) != nil
    }

    public static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard let first = needle.first, needle.count <= haystack.count else {
            return needle.isEmpty ? from : nil
        }
        let last = haystack.count - needle.count
        return haystack.withUnsafeBufferPointer { hay -> Int? in
            needle.withUnsafeBufferPointer { pattern -> Int? in
                var start = max(from, 0)
                while start <= last {
                    guard let offset = hay[start...last].firstIndex(of: first) else { return nil }
                    var step = 1
                    while step < pattern.count, hay[offset + step] == pattern[step] { step += 1 }
                    if step == pattern.count { return offset }
                    start = offset + 1
                }
                return nil
            }
        }
    }

    /// Every offset at which `needle` occurs.
    public static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        var found: [Int] = []
        var from = 0
        while let index = firstIndex(of: needle, in: haystack, from: from) {
            found.append(index)
            from = index + 1
        }
        return found
    }

    // MARK: - Character classes

    @inline(__always)
    public static func isIdentifier(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F: return true   // a-z A-Z 0-9 _
        default: return byte >= nonASCII
        }
    }

    /// Space, tab or any line break. `Character.isNewline` also covers vertical
    /// tab and form feed, which the parsers skipped as whitespace.
    @inline(__always)
    public static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    @inline(__always)
    public static func isNewline(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }
}

extension String {
    /// The UTF-8 bytes, for use as a search needle.
    var scanBytes: [UInt8] { Array(utf8) }
}
