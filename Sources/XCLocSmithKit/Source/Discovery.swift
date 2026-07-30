import Foundation

/// Project-specific localization conventions, learned from the source itself.
///
/// A view that takes a `String` and renders it through `LocalizedStringKey`
/// makes its call sites localizable: `StatRow(label: "Best Drop")` is a catalog
/// key even though `label:` means nothing to SwiftUI. The same parameter name
/// on a type that does *not* do that is an internal identifier, so the owning
/// type is recorded and checked at the call site.
public struct DiscoveredLocalizables: Equatable, Sendable {
    /// Parameter name → types that localize it.
    public var parameterOwners: [String: Set<String>] = [:]
    /// Types whose first unlabelled initializer argument is localized.
    public var initializerTypes: Set<String> = []
    /// Functions the project defines that localize their first argument, found
    /// by reading their bodies rather than by matching their names.
    public var localizedFunctions: Set<String> = []
    /// Every type declared in the scanned sources, so an unknown callee can be
    /// distinguished from one we know does not localize.
    public var declaredTypes: Set<String> = []

    public init() {}
}

enum LocalizableDiscovery {
    private static let typeDeclaration = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:struct|final class|class|actor|enum|extension)\s+([A-Z][A-Za-z0-9_]*)"#
    )
    private static let stringProperty = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*String\b"#
    )
    private static let localizedProperty = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*(?:LocalizedStringKey|LocalizedStringResource)\b"#
    )
    private static let localizedUse = try! NSRegularExpression(
        pattern: #"(?:LocalizedStringKey|LocalizedStringResource)\(\s*([A-Za-z_][A-Za-z0-9_.]*)"#
    )
    private static let unlabelledInit = try! NSRegularExpression(
        pattern: #"init\(\s*_\s+([a-z_][A-Za-z0-9_]*)\s*:\s*(?:String|LocalizedStringKey)\b"#
    )

    /// `func localizedString(_ key: String, …)` — the first parameter's name is
    /// captured so the body can be checked for passing it to a real API.
    private static let functionDeclaration = try! NSRegularExpression(
        pattern: #"func\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\(\s*(?:_\s+)?([a-z_][A-Za-z0-9_]*)\s*:\s*(?:String|StaticString)\b"#
    )

    /// Scans the comment-stripped code of every file.
    ///
    /// Each file's declarations depend on nothing outside it, so the files are
    /// read across cores and merged in file order — the result does not depend
    /// on which core finished first.
    static func discover(in files: [AnalyzedSource]) -> DiscoveredLocalizables {
        var result = DiscoveredLocalizables()
        for partial in parallelMap(files, declarations(in:)) {
            for (parameter, types) in partial.parameterOwners {
                result.parameterOwners[parameter, default: []].formUnion(types)
            }
            result.initializerTypes.formUnion(partial.initializerTypes)
            result.declaredTypes.formUnion(partial.declaredTypes)
            result.localizedFunctions.formUnion(partial.localizedFunctions)
        }
        return result
    }

    /// What one file contributes. `localizedFunctions` is gathered in the same
    /// pass rather than in a second one over the same lines.
    private struct FileDeclarations {
        var parameterOwners: [String: Set<String>] = [:]
        var initializerTypes: Set<String> = []
        var declaredTypes: Set<String> = []
        var localizedFunctions: Set<String> = []
    }

    /// Words without which the corresponding pattern cannot match. Running ICU
    /// over every line of a project this size dominated discovery; a literal
    /// byte search rejects nearly all of them first.
    private static let typeKeywords = ["struct", "class", "actor", "enum", "extension"].map(\.scanBytes)
    private static let stringWord = "String".scanBytes
    private static let localizedWord = "LocalizedString".scanBytes
    private static let initWord = "init(".scanBytes
    private static let funcWord = "func".scanBytes

    private static func declarations(in file: AnalyzedSource) -> FileDeclarations {
        var result = FileDeclarations()
        let bytes = file.lexed.bytes
        let (lines, ranges) = codeLines(of: bytes)

        var currentType: String?
        var typeDepth = 0
        var depth = 0
        var stringProperties = Set<String>()
        var localizedProperties = Set<String>()
        var localizedArguments = Set<String>()
        var unlabelledFirstParameters = Set<String>()

        func flush() {
            guard let type = currentType else { return }
            let localizable = stringProperties
                .intersection(localizedArguments)
                .union(localizedProperties)
            for parameter in localizable {
                result.parameterOwners[parameter, default: []].insert(type)
            }
            if !unlabelledFirstParameters.isDisjoint(with: localizable) {
                result.initializerTypes.insert(type)
            }
            stringProperties.removeAll()
            localizedProperties.removeAll()
            localizedArguments.removeAll()
            unlabelledFirstParameters.removeAll()
            currentType = nil
        }

        for (index, line) in lines.enumerated() {
            let span = ranges[index]
            let range = NSRange(line.startIndex..., in: line)

            if typeKeywords.contains(where: { ByteScan.contains($0, in: bytes, range: span) }),
               let match = typeDeclaration.firstMatch(in: line, range: range),
               let nameRange = Range(match.range(at: 1), in: line) {
                flush()
                let name = String(line[nameRange])
                currentType = name
                result.declaredTypes.insert(name)
                typeDepth = depth
            }

            if ByteScan.contains(funcWord, in: bytes, range: span) {
                localizedFunction(at: index, line: line, range: range, lines: lines, into: &result)
            }

            for offset in span {
                if bytes[offset] == openBrace { depth += 1 }
                if bytes[offset] == closeBrace {
                    depth -= 1
                    if currentType != nil && depth <= typeDepth { flush() }
                }
            }

            guard currentType != nil else { continue }

            if ByteScan.contains(stringWord, in: bytes, range: span) {
                for match in stringProperty.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) { stringProperties.insert(String(line[r])) }
                }
            }
            if ByteScan.contains(localizedWord, in: bytes, range: span) {
                for match in localizedProperty.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) { localizedProperties.insert(String(line[r])) }
                }
                for match in localizedUse.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let components = String(line[r]).split(separator: ".").map(String.init)
                    if let first = components.first { localizedArguments.insert(first) }
                    if let last = components.last { localizedArguments.insert(last) }
                }
            }
            if ByteScan.contains(initWord, in: bytes, range: span) {
                for match in unlabelledInit.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) {
                        unlabelledFirstParameters.insert(String(line[r]))
                    }
                }
            }
        }
        flush()
        return result
    }

    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D

    /// The lines of the comment-stripped code, each with the byte range it
    /// occupies. Building the whole file as one `String` and then walking it a
    /// `Character` at a time was most of what discovery cost.
    private static func codeLines(of bytes: [UInt8]) -> ([String], [Range<Int>]) {
        var lines: [String] = []
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            guard ByteScan.isNewline(bytes[index]) else { index += 1; continue }
            lines.append(String(decoding: bytes[start..<index], as: UTF8.self))
            ranges.append(start..<index)
            // `\r\n` is one break, so a file with Windows line endings does not
            // gain an empty line between every pair.
            index += (bytes[index] == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A) ? 2 : 1
            start = index
        }
        lines.append(String(decoding: bytes[start...], as: UTF8.self))
        ranges.append(start..<bytes.count)
        return (lines, ranges)
    }

    /// Functions the project defines that localize their first argument.
    ///
    /// Every large project in the sample wraps the platform API in one of
    /// these. HSTracker's is `String.localizedString(_:comment:)` and it is
    /// used 293 times; without recognising it the scan sees 32 user-visible
    /// strings in 1,041 files and calls 350 live keys orphaned.
    ///
    /// The evidence required is specific: the declared first parameter must be
    /// passed on to a platform localization API inside the body. A function
    /// merely *called* `localize` proves nothing.
    static func localizedFunctions(in files: [AnalyzedSource]) -> Set<String> {
        var found: Set<String> = []
        for partial in parallelMap(files, declarations(in:)) {
            found.formUnion(partial.localizedFunctions)
        }
        return found
    }

    /// One `func` line: if it declares a `String` first parameter that the body
    /// hands to a real localization API, the function's name is recorded.
    private static func localizedFunction(
        at index: Int,
        line: String,
        range: NSRange,
        lines: [String],
        into result: inout FileDeclarations
    ) {
        guard let match = functionDeclaration.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let parameterRange = Range(match.range(at: 2), in: line) else { return }
        let name = String(line[nameRange])
        guard !result.localizedFunctions.contains(name) else { return }
        let parameter = String(line[parameterRange])

        // The body, bounded by brace depth from the declaration.
        var depth = 0
        var started = false
        for bodyLine in lines[index...] {
            for character in bodyLine {
                if character == "{" { depth += 1; started = true }
                if character == "}" { depth -= 1 }
            }
            if passesToLocalizationAPI(parameter, in: bodyLine) {
                result.localizedFunctions.insert(name)
                return
            }
            if started && depth <= 0 { return }
        }
    }

    private static func passesToLocalizationAPI(_ parameter: String, in line: String) -> Bool {
        let apis = [
            "NSLocalizedString(", "String(localized:", "LocalizedStringResource(",
            "LocalizedStringKey(", "localizedString(forKey:", "AttributedString(localized:",
        ]
        guard apis.contains(where: { line.contains($0) }) else { return false }
        // The parameter has to be what is handed over, not just a name in scope.
        return line.range(of: "\\b\(NSRegularExpression.escapedPattern(for: parameter))\\b",
                          options: .regularExpression) != nil
    }

    /// Property names declared as `LocalizedStringKey` anywhere in the project.
    /// Used to avoid double-wrapping and to recognise already-localized values.
    static func localizedPropertyNames(in files: [AnalyzedSource]) -> Set<String> {
        var names = Set<String>()
        for file in files {
            let code = String(decoding: file.lexed.bytes, as: UTF8.self)
            let range = NSRange(code.startIndex..., in: code)
            for match in localizedProperty.matches(in: code, range: range) {
                if let r = Range(match.range(at: 1), in: code) { names.insert(String(code[r])) }
            }
        }
        return names
    }
}
