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
    /// The first byte value that cannot be ASCII. Every byte at or above it is
    /// part of a multi-byte UTF-8 character, which the parsers treat as an
    /// identifier character and never as a delimiter.
    public static let nonASCII: UInt8 = 0x80

    /// Literal substring search over a raw buffer.
    ///
    /// `memchr` does the skipping — it is vectorised in libc, and a plain
    /// byte-at-a-time loop over the same data is several times slower. Looking
    /// for a few hundred catalog keys in a thousand source files makes this the
    /// innermost loop of the orphan check.
    public static func firstIndex(
        of needle: UnsafeBufferPointer<UInt8>,
        in haystack: UnsafeBufferPointer<UInt8>,
        from: Int
    ) -> Int? {
        guard let first = needle.first else { return max(from, 0) }
        guard let base = haystack.baseAddress, needle.count <= haystack.count else { return nil }
        var start = max(from, 0)
        let last = haystack.count - needle.count
        while start <= last {
            guard let hit = memchr(base + start, Int32(first), last - start + 1) else { return nil }
            let offset = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
            var step = 1
            while step < needle.count, base[offset + step] == needle[step] { step += 1 }
            if step == needle.count { return offset }
            start = offset + 1
        }
        return nil
    }

    public static func contains(_ needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>) -> Bool {
        needle.withUnsafeBufferPointer { firstIndex(of: $0, in: haystack, from: 0) != nil }
    }

    public static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { firstIndex(of: $0, in: hay, from: 0) != nil }
        }
    }

    /// The same search confined to one line, for use as a cheap gate in front
    /// of a regex that cannot possibly match without this word present.
    public static func contains(_ needle: [UInt8], in haystack: [UInt8], range: Range<Int>) -> Bool {
        haystack.withUnsafeBufferPointer { hay in
            guard let base = hay.baseAddress else { return needle.isEmpty }
            let slice = UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
            return needle.withUnsafeBufferPointer { firstIndex(of: $0, in: slice, from: 0) != nil }
        }
    }

    /// Every offset at which `needle` occurs.
    public static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        var found: [Int] = []
        haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pattern in
                var from = 0
                while let index = firstIndex(of: pattern, in: hay, from: from) {
                    found.append(index)
                    from = index + 1
                }
            }
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
