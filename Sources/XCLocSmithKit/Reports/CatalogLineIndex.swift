import Foundation

/// Which line of an `.xcstrings` file a key is declared on.
///
/// A catalog finding knows its key but not its position — the catalog is parsed
/// into a dictionary, and dictionaries have no lines. That is fine in a terminal
/// and useless on a pull request, where an annotation without a line lands on
/// the first row of a four-thousand-line JSON file.
///
/// The lookup is textual on purpose. Reconstructing a position from the parser
/// would mean threading source offsets through every JSON value for the sake of
/// one output format, and the catalog format makes the textual answer exact:
/// keys are written one per line at a known indent, in Unicode order, escaped
/// the same way this tool escapes them.
struct CatalogLineIndex {
    private var lines: [String: Int] = [:]

    /// Nil when the file cannot be read — the annotation is still emitted, just
    /// without a line, which is better than losing the finding.
    init?(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let key = Self.declaredKey(in: line) else { continue }
            // First occurrence wins: a value may itself look like a key
            // declaration, and the outer one is the real entry.
            if lines[key] == nil { lines[key] = offset + 1 }
        }
    }

    func line(of key: String) -> Int? { lines[key] }

    /// The key from a line of the form `    "some.key" : {`.
    ///
    /// Anchored on the trailing `" : {` so a translation value never matches:
    /// `"value" : "Save"` ends in a string, and only a key opens an object.
    private static func declaredKey(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix(" : {") else { return nil }
        let body = trimmed.dropLast(4)
        guard body.hasSuffix("\""), body.count >= 2 else { return nil }
        return unescape(String(body.dropFirst().dropLast()))
    }

    /// The escapes Xcode's writer emits, reversed. `\/` is in the list because
    /// the catalog format escapes forward slashes, which no other JSON writer
    /// bothers with and which appears in any key containing a path or a URL.
    private static func unescape(_ value: String) -> String {
        var result = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            let next = characters[index + 1]
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "b": result.append("\u{8}")
            case "f": result.append("\u{C}")
            case "u":
                let start = index + 2
                guard start + 4 <= characters.count,
                      let scalar = UInt32(String(characters[start..<(start + 4)]), radix: 16),
                      let unicode = Unicode.Scalar(scalar) else {
                    result.append(next)
                    index += 2
                    continue
                }
                result.append(Character(unicode))
                index += 6
                continue
            default: result.append(next)   // \" \\ \/
            }
            index += 2
        }
        return result
    }
}
