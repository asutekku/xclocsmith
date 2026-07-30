import Foundation

/// Reports are the single source of truth for what a command found.
///
/// Both the human output and `--json` render from these structs, so the two can
/// never disagree — the predecessor of this tool counted findings in prose that
/// its JSON never emitted, which meant an agent working from JSON could never
/// reach a clean run.
public protocol Report {
    /// Findings that make the command fail (exit 1).
    var failures: Int { get }
    /// Findings that are reported but do not fail.
    var advisories: Int { get }
    var jsonValue: JSONValue { get }
    /// Every finding, flattened for SARIF and GitHub annotations.
    ///
    /// A protocol *requirement* rather than only an extension: a member
    /// supplied by a protocol extension alone is dispatched statically, so
    /// `render(some Report)` would call the empty default and every annotation
    /// format would silently emit nothing.
    var findings: [Finding] { get }
}

// MARK: - check

public struct PluralGap: Equatable, Sendable {
    public let key: String
    public let language: String
    public let missingCategories: [String]
}

public struct FormatMismatch: Equatable, Sendable {
    public let key: String
    public let language: String
    public let problem: String
    /// The two strings compared. An identifier key names the entry but not the
    /// defect: `"Scene.Compose.Poll.OptionNumber" has 2 specifiers` says
    /// nothing a translator can act on until they see "Option %ld" and
    /// "%ld nga %ld".
    public let source: String?
    public let translation: String?

    public init(
        key: String,
        language: String,
        problem: String,
        source: String? = nil,
        translation: String? = nil
    ) {
        self.key = key
        self.language = language
        self.problem = problem
        self.source = source
        self.translation = translation
    }
}

public struct LanguageCoverage: Equatable, Sendable {
    public let language: String
    public let translatable: Int
    public let translated: Int
    public let missing: [String]
    public let empty: [String]
    public let needsReview: [String]
    public let identicalToSource: [String]
    public let isSourceLanguage: Bool

    public var percent: Int {
        guard translatable > 0 else { return 100 }
        return Int((Double(translated) / Double(translatable) * 100).rounded())
    }

    var jsonValue: JSONValue {
        .object([
            "language": .string(language),
            "translatable": .number("\(translatable)"),
            "translated": .number("\(translated)"),
            "percent": .number("\(percent)"),
            "missing": .array(missing.map { .string($0) }),
            "empty": .array(empty.map { .string($0) }),
            "needsReview": .array(needsReview.map { .string($0) }),
            "identicalToSource": .array(identicalToSource.map { .string($0) }),
            "isSourceLanguage": .bool(isSourceLanguage),
        ])
    }
}

public struct CatalogReport: Equatable, Sendable {
    public let path: String
    public let table: String
    public let sourceLanguage: String
    public let keyCount: Int
    public let translatableCount: Int
    public let staleKeys: [String]
    public let untranslatableKeys: [String]
    public let doNotTranslateKeys: [String]
    public let coverage: [LanguageCoverage]
    public let caseDuplicates: [CaseDuplicate]
    public let similarKeys: [SimilarPair]
    public let duplicateSources: [DuplicateSource]
    public let glossaryViolations: [GlossaryViolation]
    public let pluralGaps: [PluralGap]
    public let formatMismatches: [FormatMismatch]
    /// Keys the source language pluralises, so a template can ask for the
    /// target language's plural forms rather than a flat string.
    public let pluralisedKeys: [String]

    var jsonValue: JSONValue {
        .object([
            "catalog": .string(path),
            "table": .string(table),
            "sourceLanguage": .string(sourceLanguage),
            "keys": .number("\(keyCount)"),
            "translatable": .number("\(translatableCount)"),
            "stale": .array(staleKeys.map { .string($0) }),
            "notTranslatable": .array(untranslatableKeys.map { .string($0) }),
            "shouldNotTranslate": .array(doNotTranslateKeys.map { .string($0) }),
            "languages": .array(coverage.map(\.jsonValue)),
            "caseDuplicates": .array(caseDuplicates.map { duplicate in
                .object([
                    "keys": .array(duplicate.keys.map { .string($0) }),
                    "breaksSymbolGeneration": .bool(duplicate.breaksSymbolGeneration),
                ])
            }),
            "similarKeys": .array(similarKeys.map { pair in
                var fields: [String: JSONValue] = [
                    "a": .string(pair.a),
                    "b": .string(pair.b),
                    "similarity": .number("\(pair.percent)"),
                ]
                if let text = pair.aText { fields["aText"] = .string(text) }
                if let text = pair.bText { fields["bText"] = .string(text) }
                return .object(fields)
            }),
            "duplicateSources": .array(duplicateSources.map { duplicate in
                .object([
                    "text": .string(duplicate.text),
                    "keys": .array(duplicate.keys.map { .string($0) }),
                    "divergences": .array(duplicate.divergences.map { divergence in
                        .object([
                            "language": .string(divergence.language),
                            "renderings": .array(divergence.renderings.map { rendering in
                                .object([
                                    "key": .string(rendering.key),
                                    "value": .string(rendering.value),
                                ])
                            }),
                        ])
                    }),
                ])
            }),
            "glossaryViolations": .array(glossaryViolations.map { violation in
                .object([
                    "key": .string(violation.key),
                    "language": .string(violation.language),
                    "term": .string(violation.term),
                    "expected": .string(violation.expected),
                    "source": .string(violation.source),
                    "translation": .string(violation.translation),
                ])
            }),
            "pluralGaps": .array(pluralGaps.map { gap in
                .object([
                    "key": .string(gap.key),
                    "language": .string(gap.language),
                    "missingCategories": .array(gap.missingCategories.map { .string($0) }),
                ])
            }),
            "formatMismatches": .array(formatMismatches.map { mismatch in
                var fields: [String: JSONValue] = [
                    "key": .string(mismatch.key),
                    "language": .string(mismatch.language),
                    "problem": .string(mismatch.problem),
                ]
                if let source = mismatch.source { fields["source"] = .string(source) }
                if let translation = mismatch.translation {
                    fields["translation"] = .string(translation)
                }
                return .object(fields)
            }),
        ])
    }
}

public struct CheckReport: Report {
    public var catalogs: [CatalogReport] = []
    public var diagnostics: [DiagnosticError] = []
    public var templatesWritten: [String] = []

    public var failures: Int {
        var total = diagnostics.count
        for catalog in catalogs {
            for coverage in catalog.coverage where !coverage.isSourceLanguage {
                total += coverage.missing.count + coverage.empty.count
            }
            total += catalog.caseDuplicates.filter(\.breaksSymbolGeneration).count
            total += catalog.pluralGaps.count
            total += catalog.formatMismatches.count
            // A glossary is opt-in, so a violation is a decision the project
            // wrote down and a translation broke.
            total += catalog.glossaryViolations.count
        }
        return total
    }

    public var advisories: Int {
        catalogs.reduce(0) { total, catalog in
            total
                + catalog.similarKeys.count
                // Advisory, not a failure: "Free" the price and "Free" the
                // availability are one string with two right answers, and a
                // project that has shipped for years has hundreds of these.
                // `--strict` promotes them for anyone who wants the ratchet.
                + catalog.duplicateSources.count
                + catalog.caseDuplicates.filter { !$0.breaksSymbolGeneration }.count
                + catalog.coverage.reduce(0) { $0 + $1.needsReview.count + $1.identicalToSource.count }
                + catalog.staleKeys.count
        }
    }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("check"),
            "catalogs": .array(catalogs.map(\.jsonValue)),
            "diagnostics": .array(diagnostics.map { diagnostic in
                .object(["path": .string(diagnostic.path), "message": .string(diagnostic.message)])
            }),
            "templatesWritten": .array(templatesWritten.map { .string($0) }),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ])
    }
}

// MARK: - scan

public struct MissingKeyFinding: Equatable, Sendable {
    public let value: String
    public let file: String
    public let line: Int
    public let context: String
    public let catalog: String
    public let table: String
    public let isFormatKey: Bool

    var jsonValue: JSONValue {
        .object([
            "value": .string(value),
            "file": .string(file),
            "line": .number("\(line)"),
            "context": .string(context),
            "catalog": .string(catalog),
            "table": .string(table),
            "isFormatKey": .bool(isFormatKey),
        ])
    }
}

public struct UntranslatedFinding: Equatable, Sendable {
    public let value: String
    public let file: String
    public let line: Int
    public let context: String
    public let catalog: String
    public let language: String

    var jsonValue: JSONValue {
        .object([
            "value": .string(value),
            "file": .string(file),
            "line": .number("\(line)"),
            "context": .string(context),
            "catalog": .string(catalog),
            "language": .string(language),
        ])
    }
}

public struct OrphanFinding: Equatable, Sendable {
    public let catalog: String
    public let keys: [String]

    var jsonValue: JSONValue {
        .object(["catalog": .string(catalog), "keys": .array(keys.map { .string($0) })])
    }
}

public struct ScanReport: Report {
    public var filesScanned = 0
    public var stringsFound = 0
    public var missingKeys: [MissingKeyFinding] = []
    public var untranslated: [UntranslatedFinding] = []
    public var bypasses: [BypassWarning] = []
    public var orphans: [OrphanFinding] = []
    public var templatesWritten: [String] = []
    public var diagnostics: [DiagnosticError] = []
    public var discoveredParameters: [String: [String]] = [:]
    /// Set when a call computes its table name, so attribution is incomplete.
    public var hasDynamicTables = false
    /// Strings that resolve to a legacy `.strings` file rather than a catalog:
    /// localized, but not by anything this tool audits.
    public var resolvedInLegacyStrings = 0
    public var legacyStringsFiles = 0
    public var testFilesSkipped = 0
    /// Non-empty when `--files` narrowed the run, so the reader knows the
    /// orphan check did not happen rather than assuming it came back clean.
    public var limitedToFiles: [String] = []
    /// Paths `--files` named that are in no target's sources.
    public var unscannedFiles: [String] = []

    public var failures: Int { missingKeys.count + untranslated.count + diagnostics.count }
    public var advisories: Int { bypasses.count + orphans.reduce(0) { $0 + $1.keys.count } }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("scan"),
            "filesScanned": .number("\(filesScanned)"),
            "stringsFound": .number("\(stringsFound)"),
            "resolvedInLegacyStrings": .number("\(resolvedInLegacyStrings)"),
            "legacyStringsFiles": .number("\(legacyStringsFiles)"),
            "testFilesSkipped": .number("\(testFilesSkipped)"),
            "limitedToFiles": .array(limitedToFiles.map { .string($0) }),
            "unscannedFiles": .array(unscannedFiles.map { .string($0) }),
            "orphansChecked": .bool(limitedToFiles.isEmpty),
            "missingKeys": .array(missingKeys.map(\.jsonValue)),
            "untranslated": .array(untranslated.map(\.jsonValue)),
            "bypasses": .array(bypasses.map { bypass in
                .object([
                    "file": .string(bypass.file),
                    "line": .number("\(bypass.line)"),
                    "reason": .string(bypass.reason),
                    "snippet": .string(bypass.snippet),
                ])
            }),
            "orphans": .array(orphans.map(\.jsonValue)),
            "templatesWritten": .array(templatesWritten.map { .string($0) }),
            "diagnostics": .array(diagnostics.map { diagnostic in
                .object(["path": .string(diagnostic.path), "message": .string(diagnostic.message)])
            }),
            "hasDynamicTables": .bool(hasDynamicTables),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ])
    }
}

// MARK: - write commands

public struct WriteReport: Report {
    public enum Action: String, Sendable {
        case registered, translated, updated, skipped, removed
    }

    /// Why a key was not written. The reason travels with the key: "not in the
    /// catalog" and "would destroy plural variations" call for different fixes,
    /// and one message for both sends people to the wrong one.
    public struct Refusal: Equatable, Sendable {
        public let key: String
        public let reason: String

        public init(key: String, reason: String) {
            self.key = key
            self.reason = reason
        }
    }

    public struct Change: Equatable, Sendable {
        public let key: String
        public let action: String
        public let detail: String?

        public init(key: String, action: Action, detail: String? = nil) {
            self.key = key
            self.action = action.rawValue
            self.detail = detail
        }
    }

    public var catalog: String
    public var language: String?
    public var changes: [Change] = []
    public var conflicts: [(key: String, existing: String)] = []
    public var refusals: [Refusal] = []
    public var dryRun = false

    public init(catalog: String, language: String? = nil) {
        self.catalog = catalog
        self.language = language
    }

    public func count(_ action: Action) -> Int {
        changes.filter { $0.action == action.rawValue }.count
    }

    public var failures: Int { conflicts.count + refusals.count }
    public var advisories: Int { 0 }

    public var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "catalog": .string(catalog),
            "advisories": .number("\(advisories)"),
            "dryRun": .bool(dryRun),
            "changes": .array(changes.map { change in
                var entry: [String: JSONValue] = [
                    "key": .string(change.key),
                    "action": .string(change.action),
                ]
                if let detail = change.detail { entry["detail"] = .string(detail) }
                return .object(entry)
            }),
            "caseConflicts": .array(conflicts.map { conflict in
                .object(["key": .string(conflict.key), "existing": .string(conflict.existing)])
            }),
            "refusals": .array(refusals.map { refusal in
                .object(["key": .string(refusal.key), "reason": .string(refusal.reason)])
            }),
            "failures": .number("\(failures)"),
        ]
        if let language { fields["language"] = .string(language) }
        return .object(fields)
    }
}

// MARK: - lookup

public struct LookupReport: Report {
    public struct Match: Equatable, Sendable {
        public let key: String
        public let catalog: String
        public let kind: String     // exact | caseVariant | contains | similar
        public let similarity: Int?
        public let translations: [String: String]
    }

    public var query: String
    public var matches: [Match] = []

    public init(query: String) { self.query = query }

    public var failures: Int { matches.isEmpty ? 1 : 0 }
    public var advisories: Int { 0 }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("lookup"),
            "query": .string(query),
            "matches": .array(matches.map { match in
                var fields: [String: JSONValue] = [
                    "key": .string(match.key),
                    "catalog": .string(match.catalog),
                    "kind": .string(match.kind),
                    "translations": .object(match.translations.mapValues { .string($0) }),
                ]
                if let similarity = match.similarity { fields["similarity"] = .number("\(similarity)") }
                return .object(fields)
            }),
            "found": .bool(!matches.isEmpty),
        ])
    }
}

/// Several lookups in one run.
public struct LookupReports: Report {
    public var reports: [LookupReport] = []
    public init(reports: [LookupReport] = []) { self.reports = reports }

    public var failures: Int { reports.allSatisfy { $0.matches.isEmpty } && !reports.isEmpty ? 1 : 0 }
    public var advisories: Int { 0 }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("lookup"),
            "queries": .array(reports.map(\.jsonValue)),
            "found": .bool(reports.contains { !$0.matches.isEmpty }),
        ])
    }
}


/// Several catalogs written in one command, so `prune` and `xcloc apply` report
/// through the same mechanism as everything else instead of hand-rolling JSON.
public struct WriteReports: Report {
    public let command: String
    public let reports: [WriteReport]

    public init(command: String, reports: [WriteReport]) {
        self.command = command
        self.reports = reports
    }

    public var failures: Int { reports.reduce(0) { $0 + $1.failures } }
    public var advisories: Int { reports.reduce(0) { $0 + $1.advisories } }

    public var jsonValue: JSONValue {
        .object([
            "command": .string(command),
            "catalogs": .array(reports.map(\.jsonValue)),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ])
    }
}
