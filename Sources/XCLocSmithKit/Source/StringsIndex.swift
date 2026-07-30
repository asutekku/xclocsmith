import Foundation

/// The keys a project still keeps in legacy `.strings` files.
///
/// This tool audits `.xcstrings` and nothing else — it does not check `.strings`
/// coverage, translate them, or offer to edit them. It reads them for one
/// reason: to avoid claiming a key is unlocalized when the project localizes it
/// somewhere this tool does not manage.
///
/// Migration to string catalogs is gradual and partial by design; Xcode
/// converts one table at a time. Every large project in the sample was
/// mid-migration, and without this DuckDuckGo's 20,323 `NSLocalizedString`
/// calls all read as missing.
public struct StringsIndex: Sendable {
    /// Table name → keys declared in any `.strings` file for that table.
    private var keysByTable: [String: Set<String>] = [:]
    public private(set) var fileCount = 0

    public init() {}

    public var isEmpty: Bool { keysByTable.isEmpty }

    /// Tables that exist only as `.strings`, sorted — worth naming in the
    /// report so the gap in coverage is visible rather than silent.
    public var tables: [String] { keysByTable.keys.sorted() }

    public func contains(_ key: String, table: String?) -> Bool {
        keysByTable[table ?? "Localizable"]?.contains(key) ?? false
    }

    /// Scans for `*.lproj/*.strings` under the configured roots.
    ///
    /// Only key *presence* is collected, and only from the base or development
    /// language: a key that exists solely in a Japanese `.strings` is not
    /// evidence that the source declares it.
    public static func build(root: String, configuration: Configuration) -> StringsIndex {
        var index = StringsIndex()
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return index }

        while let relative = enumerator.nextObject() as? String {
            let components = relative.split(separator: "/").map(String.init)
            if let last = components.last,
               configuration.excludedDirectories.contains(last) || ProjectDiscovery.isOpaqueBundle(last) {
                enumerator.skipDescendants()
                continue
            }
            guard relative.hasSuffix(".strings"), components.count >= 2 else { continue }
            let folder = components[components.count - 2]
            guard folder.hasSuffix(".lproj") else { continue }
            let language = String(folder.dropLast(".lproj".count))
            guard StringsIndex.isBaseLanguage(language) else { continue }

            let path = URL(fileURLWithPath: root).appendingPathComponent(relative).path
            guard !configuration.isExcluded(path),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            let table = String(components[components.count - 1].dropLast(".strings".count))
            index.keysByTable[table, default: []].formUnion(StringsFile.keys(in: text))
            index.fileCount += 1
        }
        return index
    }

    /// `Base.lproj` and `en.lproj` hold the strings the source itself declares.
    /// Xcode also accepts region forms like `en-US`.
    static func isBaseLanguage(_ language: String) -> Bool {
        let lowered = language.lowercased()
        return lowered == "base" || lowered == "en" || lowered.hasPrefix("en-") || lowered.hasPrefix("en_")
    }
}

/// A minimal `.strings` reader: enough to list keys, not to validate the file.
enum StringsFile {
    static func keys(in text: String) -> Set<String> {
        var keys: Set<String> = []
        var scalars = Array(text.unicodeScalars)
        var index = 0

        func skipTrivia() {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    index += 2
                    while index + 1 < scalars.count,
                          !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                    index = min(index + 2, scalars.count)
                } else {
                    return
                }
            }
        }

        /// A quoted string, honouring backslash escapes.
        func readQuoted() -> String? {
            guard index < scalars.count, scalars[index] == "\"" else { return nil }
            index += 1
            var value = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\\", index + 1 < scalars.count {
                    value.append(unescape(scalars[index + 1]))
                    index += 2
                    continue
                }
                if scalar == "\"" {
                    index += 1
                    return String(value)
                }
                value.append(scalar)
                index += 1
            }
            return nil
        }

        /// An unquoted key, which the format allows for identifier-shaped names.
        func readBare() -> String? {
            var value = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                guard scalar != "=", scalar != ";", scalar != " ", scalar != "\n", scalar != "\t",
                      scalar != "\r" else { break }
                value.append(scalar)
                index += 1
            }
            return value.isEmpty ? nil : String(value)
        }

        while index < scalars.count {
            skipTrivia()
            guard index < scalars.count else { break }
            guard let key = readQuoted() ?? readBare() else { index += 1; continue }
            keys.insert(key)
            // Skip to the end of the statement so a value containing `"` or `;`
            // is never mistaken for the next key.
            skipTrivia()
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                skipTrivia()
                if readQuoted() == nil { _ = readBare() }
            }
            skipTrivia()
            if index < scalars.count, scalars[index] == ";" { index += 1 }
        }
        return keys
    }

    private static func unescape(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return scalar
        }
    }
}
