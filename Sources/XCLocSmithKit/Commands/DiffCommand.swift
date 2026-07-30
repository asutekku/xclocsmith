import Foundation

/// What changed between two versions of a catalog, in terms a reviewer cares
/// about rather than in terms of JSON.
///
/// The finding this exists for is a **source string that changed while its
/// translations did not**. Xcode marks a translation `needs_review` when *it*
/// notices the source move, but only for edits made in its own editor: a string
/// changed by an `add`, a merge, a script, or a hand edit leaves every
/// translation reading `translated` and saying the wrong thing. IceCubesApp
/// ships one — an English string became "%lld posts" and its Belarusian still
/// reads "%lld people talking" — and nothing in the catalog records that it is
/// wrong. A line-by-line `git diff` shows the source moved; it cannot tell you
/// which of the nineteen translations underneath were left behind.
public struct DiffCommand {
    public struct Options {
        /// Languages to compare. Empty means every language either side has.
        public var languages: [String]

        public init(languages: [String] = []) {
            self.languages = languages
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func run(before: Catalog, after: Catalog) -> CatalogDiff {
        var diff = CatalogDiff(catalog: after.displayPath)

        let old = Set(before.keys)
        let new = Set(after.keys)
        diff.addedKeys = new.subtracting(old).sorted()
        diff.removedKeys = old.subtracting(new).sorted()

        let sourceLanguage = after.sourceLanguage
        if before.sourceLanguage != sourceLanguage {
            diff.sourceLanguageChanged = before.sourceLanguage
        }

        for key in new.intersection(old).sorted() {
            let wasSource = before.displayText(key, before.sourceLanguage)
            let isSource = after.displayText(key, sourceLanguage)
            guard let wasSource, let isSource, wasSource != isSource else {
                // The source is unchanged, so a changed translation is somebody
                // improving a translation, which is not a finding.
                continue
            }

            let languages = self.languages(before: before, after: after, sourceLanguage: sourceLanguage)
            var unchanged: [String] = []
            var updated: [String] = []
            for language in languages {
                guard let wasText = before.displayText(key, language), !wasText.isEmpty else { continue }
                guard let isText = after.displayText(key, language), !isText.isEmpty else { continue }
                // A translation Xcode has already flagged needs no second
                // flagging: the catalog is carrying the warning itself.
                if after.status(key, language).needsReview { continue }
                if wasText == isText { unchanged.append(language) } else { updated.append(language) }
            }

            diff.sourceChanges.append(SourceChange(
                key: key,
                before: wasSource,
                after: isSource,
                staleLanguages: unchanged.sorted(),
                updatedLanguages: updated.sorted()
            ))
        }

        return diff
    }

    /// Compare each catalog against the version at a git reference.
    ///
    /// A catalog that does not exist at the reference is new, and every key in
    /// it is an addition — not an error. That distinction only holds because
    /// the reference itself is verified first: without that check, a mistyped
    /// ref makes *every* file look new and the run reports nothing wrong.
    public func run(
        reference: String,
        catalogs: [Catalog],
        repositoryRoot: String
    ) throws -> DiffReport {
        guard Git.resolves(reference: reference, directory: repositoryRoot) else {
            throw SmithError.usage("\"\(reference)\" is not a commit this repository knows")
        }
        var report = DiffReport(reference: reference)
        let root = URL(fileURLWithPath: repositoryRoot).resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"

        for catalog in catalogs {
            guard catalog.path.hasPrefix(prefix) else {
                report.diagnostics.append(DiagnosticError(
                    path: catalog.displayPath,
                    message: "is outside the git repository at \(root)"
                ))
                continue
            }
            let relative = String(catalog.path.dropFirst(prefix.count))
            guard let data = try? Git.show(
                reference: reference,
                path: relative,
                directory: repositoryRoot
            ) else {
                var diff = CatalogDiff(catalog: catalog.displayPath)
                diff.addedKeys = catalog.keys.sorted()
                diff.isNew = true
                report.catalogs.append(diff)
                continue
            }
            do {
                let before = try Catalog(
                    data: data,
                    path: catalog.path,
                    displayPath: catalog.displayPath
                )
                report.catalogs.append(run(before: before, after: catalog))
            } catch {
                report.diagnostics.append(DiagnosticError(
                    path: catalog.displayPath,
                    message: "at \(reference): \(error)"
                ))
            }
        }
        return report
    }

    private func languages(before: Catalog, after: Catalog, sourceLanguage: String) -> [String] {
        if !options.languages.isEmpty {
            return options.languages.filter { $0 != sourceLanguage }
        }
        return Set(before.languages).union(after.languages)
            .subtracting([sourceLanguage])
            .sorted()
    }
}

/// A source string that moved, and what happened to its translations.
public struct SourceChange: Equatable, Sendable {
    public let key: String
    public let before: String
    public let after: String
    /// Translations that did not move with it and are not marked for review.
    /// These are the ones now saying something the source no longer says.
    public let staleLanguages: [String]
    /// Translations that were updated in the same change.
    public let updatedLanguages: [String]
}

public struct CatalogDiff: Equatable, Sendable {
    public let catalog: String
    public var addedKeys: [String] = []
    public var removedKeys: [String] = []
    public var sourceChanges: [SourceChange] = []
    /// Set when the catalog's own source language changed, which reinterprets
    /// every string in it.
    public var sourceLanguageChanged: String?
    /// True when the catalog did not exist at the reference at all.
    public var isNew = false

    public init(catalog: String) {
        self.catalog = catalog
    }

    /// Source changes that left at least one translation behind.
    public var stranding: [SourceChange] {
        sourceChanges.filter { !$0.staleLanguages.isEmpty }
    }

    var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "catalog": .string(catalog),
            "isNew": .bool(isNew),
            "addedKeys": .array(addedKeys.map { .string($0) }),
            "removedKeys": .array(removedKeys.map { .string($0) }),
            "sourceChanges": .array(sourceChanges.map { change in
                .object([
                    "key": .string(change.key),
                    "before": .string(change.before),
                    "after": .string(change.after),
                    "staleLanguages": .array(change.staleLanguages.map { .string($0) }),
                    "updatedLanguages": .array(change.updatedLanguages.map { .string($0) }),
                ])
            }),
        ]
        if let sourceLanguageChanged {
            fields["previousSourceLanguage"] = .string(sourceLanguageChanged)
        }
        return .object(fields)
    }
}

public struct DiffReport: Report {
    public var catalogs: [CatalogDiff] = []
    public var diagnostics: [DiagnosticError] = []
    /// What the comparison was against, for the summary line.
    public var reference: String?

    public init(catalogs: [CatalogDiff] = [], reference: String? = nil) {
        self.catalogs = catalogs
        self.reference = reference
    }

    /// Only stranded translations fail. A key being added or removed is what a
    /// commit is *for*; a translation left saying the old thing is a defect
    /// that ships.
    /// Counted per changed string rather than per language, matching the
    /// finding it produces: one string to look at, however many translations
    /// are behind it.
    public var failures: Int {
        diagnostics.count + catalogs.reduce(0) { $0 + $1.stranding.count }
    }

    public var advisories: Int {
        catalogs.reduce(0) { total, diff in
            total + diff.addedKeys.count + diff.removedKeys.count
                + (diff.sourceLanguageChanged == nil ? 0 : 1)
        }
    }

    public var findings: [Finding] {
        var findings: [Finding] = []
        for diff in catalogs {
            if let previous = diff.sourceLanguageChanged {
                findings.append(Finding(
                    rule: "source-language-changed",
                    level: .warning,
                    message: "Source language changed from \(previous); every string is reinterpreted.",
                    file: diff.catalog
                ))
            }
            for change in diff.stranding {
                findings.append(Finding(
                    rule: "stale-translation",
                    level: .error,
                    message: "\"\(change.key)\" changed from \"\(change.before)\" to "
                        + "\"\(change.after)\", but \(change.staleLanguages.joined(separator: ", ")) "
                        + "still \(change.staleLanguages.count == 1 ? "reads" : "read") the old text.",
                    file: diff.catalog,
                    key: change.key
                ))
            }
            for key in diff.addedKeys {
                findings.append(Finding(
                    rule: "key-added",
                    level: .note,
                    message: "\"\(key)\" is new.",
                    file: diff.catalog,
                    key: key
                ))
            }
            for key in diff.removedKeys {
                findings.append(Finding(
                    rule: "key-removed",
                    level: .note,
                    message: "\"\(key)\" is gone.",
                    file: diff.catalog
                ))
            }
        }
        findings.append(contentsOf: diagnostics.map(\.finding))
        return findings
    }

    public var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "command": .string("diff"),
            "catalogs": .array(catalogs.map(\.jsonValue)),
            "diagnostics": .array(diagnostics.map { diagnostic in
                .object(["path": .string(diagnostic.path), "message": .string(diagnostic.message)])
            }),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ]
        if let reference { fields["reference"] = .string(reference) }
        return .object(fields)
    }
}
