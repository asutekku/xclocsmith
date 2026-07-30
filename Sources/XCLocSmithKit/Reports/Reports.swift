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
    public let pluralGaps: [PluralGap]
    public let formatMismatches: [FormatMismatch]

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
                .object([
                    "a": .string(pair.a),
                    "b": .string(pair.b),
                    "similarity": .number("\(pair.percent)"),
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
                .object([
                    "key": .string(mismatch.key),
                    "language": .string(mismatch.language),
                    "problem": .string(mismatch.problem),
                ])
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
        }
        return total
    }

    public var advisories: Int {
        catalogs.reduce(0) { total, catalog in
            total
                + catalog.similarKeys.count
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

    public var failures: Int { missingKeys.count + untranslated.count + diagnostics.count }
    public var advisories: Int { bypasses.count + orphans.reduce(0) { $0 + $1.keys.count } }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("scan"),
            "filesScanned": .number("\(filesScanned)"),
            "stringsFound": .number("\(stringsFound)"),
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
    public var refusals: [String] = []
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
            "refusals": .array(refusals.map { .string($0) }),
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
