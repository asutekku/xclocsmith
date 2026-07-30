import Foundation

/// A Swift file, tokenised once and reused by every command.
public struct AnalyzedSource {
    public let path: String
    public let displayPath: String
    public let text: String
    public let lexed: LexedSource

    public init(path: String, displayPath: String, text: String) {
        self.path = path
        self.displayPath = displayPath
        self.text = text
        self.lexed = SwiftLexer.lex(text)
    }

    public static func load(path: String, displayPath: String) throws -> AnalyzedSource {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw SmithError.cannotRead(path: displayPath, reason: "not valid UTF-8 text")
        }
        return AnalyzedSource(path: path, displayPath: displayPath, text: text)
    }

    public func line(_ number: Int) -> String {
        let lines = splitLines(text)
        guard number >= 1, number <= lines.count else { return "" }
        return lines[number - 1].trimmingCharacters(in: .whitespaces)
    }

    /// Test code, which is never localized.
    ///
    /// The import is the reliable signal — a file that imports XCTest or
    /// Swift Testing is a test whatever it is called. Path heuristics catch the
    /// fixtures and builders beside it, which import neither but exist only to
    /// serve them: DuckDuckGo's `makeTab(title:)` and `makeBookmark(title:)`
    /// accounted for 6,140 findings on their own.
    public var isTestCode: Bool {
        let code = lexed.code
        if code.contains("import XCTest") || code.contains("@testable import") { return true }
        if code.contains("import Testing"), code.contains("@Test") { return true }

        let components = displayPath.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        if name.hasSuffix("Tests.swift") || name.hasSuffix("Test.swift")
            || name.hasSuffix("Spec.swift") || name.hasSuffix("TestCase.swift") { return true }
        return components.dropLast().contains { directory in
            directory.hasSuffix("Tests") || directory.hasSuffix("TestSupport")
                || directory == "Tests" || directory == "TestUtilities"
        }
    }
}

/// One user-visible string found in source.
public struct FoundString: Equatable, Sendable {
    public let value: String
    public let file: String
    public let line: Int
    /// How it was recognised, e.g. `Text` or `StatRow(label:)`.
    public let context: String
    /// The table it belongs to, `nil` for the default table.
    public let table: String?
    /// True for interpolated literals, whose key contains format specifiers.
    public let isFormatKey: Bool
    /// Regex matching the catalog keys this interpolation could produce.
    public let formatPattern: String?
}

public struct BypassWarning: Equatable, Sendable {
    public let file: String
    public let line: Int
    public let reason: String
    public let snippet: String
}

public struct SourceScanResult {
    public var strings: [FoundString] = []
    public var bypasses: [BypassWarning] = []
    /// Every literal value seen anywhere, including previews, comments-free
    /// nested interpolation operands and non-localizable contexts. Used to
    /// decide whether a catalog key is still referenced — deliberately broad,
    /// because a false "orphan" gets a live key deleted.
    public var referencedValues = Set<String>()
    /// Regexes built from interpolated literals, matching format keys.
    public var formatPatterns = Set<String>()
    /// True when some call computes its table name, so table attribution is
    /// incomplete and orphan pruning must be conservative.
    public var hasDynamicTables = false
}

public enum SourceAnalyzer {
    /// Extracts user-visible strings, bypasses and references from one file.
    public static func analyze(
        file: AnalyzedSource,
        discovered: DiscoveredLocalizables,
        options: ClassifierOptions,
        includePreviews: Bool,
        ignoredStrings: Set<String>
    ) -> SourceScanResult {
        var result = SourceScanResult()
        guard !file.lexed.isFileIgnored else { return result }

        var analyzer = CallSiteAnalyzer(code: file.lexed.code)
        analyzer.literalsByStart = Dictionary(
            file.lexed.literals.map { ($0.start, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for literal in file.lexed.literals {
            // References are collected before any filtering: a key mentioned in
            // a preview or a debug string is still a key someone can reach.
            if literal.hasInterpolation {
                if let pattern = literal.formatPattern { result.formatPatterns.insert(pattern) }
            } else {
                result.referencedValues.insert(literal.value)
            }

            if file.lexed.ignoredLines.contains(literal.line) { continue }
            if !includePreviews && file.lexed.isInsidePreview(literal) { continue }

            let context = analyzer.context(for: literal)
            if context.tableIsDynamic { result.hasDynamicTables = true }

            let role = Classifier.classify(
                literal: literal,
                context: context,
                discovered: discovered,
                options: options
            )

            switch role {
            case .ignored:
                continue

            case .bypass(let reason):
                result.bypasses.append(BypassWarning(
                    file: file.displayPath,
                    line: literal.line,
                    reason: reason,
                    snippet: String(file.line(literal.line).prefix(90))
                ))

            case .key(let contextName, let table, let confidence):
                if context.isConcatenated {
                    result.bypasses.append(BypassWarning(
                        file: file.displayPath,
                        line: literal.line,
                        reason: "string concatenation defeats catalog lookup",
                        snippet: String(file.line(literal.line).prefix(90))
                    ))
                    // A fragment is not a key and never will be. Reporting it
                    // as missing too tells a translator to add "Are you sure
                    // you want to delete " to the catalog, when the fix is to
                    // stop building the sentence by concatenation.
                    result.referencedValues.insert(literal.value)
                    continue
                }

                if literal.hasInterpolation {
                    // The catalog key is the interpolated form: "Hello \(name)"
                    // is stored as "Hello %@". We cannot know the specifier
                    // types statically, so the pattern matches any of them.
                    guard let pattern = literal.formatPattern else { continue }
                    // Judge the key that would be extracted, not the source
                    // text: `Text("\(name)")` extracts to "%@", which has
                    // nothing in it for a translator to act on. Filtering on
                    // the raw literal instead sees the word `name` and demands
                    // a catalog entry for a string that is pure interpolation.
                    let key = literal.formatKey ?? literal.value
                    guard isReportable(key, confidence: confidence),
                          !ignoredStrings.contains(key) else { continue }
                    result.strings.append(FoundString(
                        value: key,
                        file: file.displayPath,
                        line: literal.line,
                        context: contextName,
                        table: table,
                        isFormatKey: true,
                        formatPattern: pattern
                    ))
                    continue
                }

                let value = literal.value
                guard isReportable(value, confidence: confidence),
                      !ignoredStrings.contains(value) else { continue }
                result.strings.append(FoundString(
                    value: value,
                    file: file.displayPath,
                    line: literal.line,
                    context: contextName,
                    table: table,
                    isFormatKey: false,
                    formatPattern: nil
                ))
            }
        }
        return result
    }

    /// Filters out literals that are not really user-visible text.
    ///
    /// The identifier heuristic — one lowercase word, no spaces — only applies
    /// when the context is weak. `Button("cancel")` is a catalog key because
    /// the API says so, and dropping it because it looks like an identifier
    /// hides exactly what this tool exists to find.
    static func isReportable(_ value: String, confidence: KeyConfidence = .weak) -> Bool {
        guard value.count > 1 else { return false }
        if Double(value) != nil { return false }
        guard KeyHeuristics.isTranslatable(value) else { return false }
        if confidence == .weak,
           !value.contains(" "), value.first?.isLowercase == true,
           value.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return false
        }
        return true
    }
}

public enum KeyHeuristics {
    /// A key Xcode generated from a XIB or storyboard: an object identifier
    /// and the property it sets, `3aJ-8X-AqP.title`.
    ///
    /// These can never be referenced from code — the identifier only exists
    /// inside the nib — so they are exempt from the orphan check for the same
    /// reason `InfoPlist.xcstrings` is. HSTracker keeps 23 such catalogs and
    /// they accounted for every one of its 515 reported orphans.
    public static func isInterfaceBuilderKey(_ key: String) -> Bool {
        guard let dot = key.firstIndex(of: "."), key.index(after: dot) < key.endIndex else { return false }
        let identifier = key[key.startIndex..<dot].split(separator: "-", omittingEmptySubsequences: false)
        guard identifier.count == 3 else { return false }
        let lengths = identifier.map(\.count)
        guard lengths == [3, 2, 3] else { return false }
        return identifier.allSatisfy { part in part.allSatisfy { $0.isLetter || $0.isNumber } }
    }

    /// True when a key contains text a translator could act on. `"%@"`,
    /// `"%lld/%lld"`, `"—"` and `"12"` do not.
    public static func isTranslatable(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if trimmed.count <= 2 && !first.isLetter { return false }

        var stripped = trimmed
        for specifier in FormatSpecifierScanner.specifiers(in: trimmed) {
            stripped = stripped.replacingOccurrences(of: specifier.raw, with: "")
        }
        for name in FormatSpecifierScanner.substitutionReferences(in: trimmed) {
            stripped = stripped.replacingOccurrences(of: "%#@\(name)@", with: "")
        }
        return stripped.rangeOfCharacter(from: .letters) != nil
    }
}
