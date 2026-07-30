import Foundation

/// Translation coverage and catalog health, per catalog and per language.
public struct CheckCommand {
    public struct Options {
        public var languages: [String]
        public var templatePath: String?

        public init(languages: [String] = [], templatePath: String? = nil) {
            self.languages = languages
            self.templatePath = templatePath
        }
    }

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run(catalogPaths: [String]? = nil) throws -> CheckReport {
        var report = CheckReport()

        let catalogs: [Catalog]
        if let catalogPaths {
            catalogs = catalogPaths.compactMap { workspace.catalog(at: $0) }
        } else {
            catalogs = workspace.allCatalogs()
        }

        for catalog in catalogs {
            report.catalogs.append(try analyze(catalog))
        }
        report.diagnostics = workspace.diagnostics

        if let templatePath = options.templatePath {
            // One template per (catalog, language). Pooling them would attribute
            // every key to the first catalog and the first language, and `add`
            // would then create them in the wrong file.
            struct Bucket: Hashable {
                let catalog: String
                let language: String
            }
            var buckets: [Bucket: [String]] = [:]
            for catalogReport in report.catalogs {
                for coverage in catalogReport.coverage where !coverage.isSourceLanguage {
                    let outstanding = (coverage.missing + coverage.empty).sorted()
                    guard !outstanding.isEmpty else { continue }
                    buckets[Bucket(catalog: catalogReport.path, language: coverage.language)] = outstanding
                }
            }
            for (bucket, keys) in buckets.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                let path = TemplateNaming.path(
                    base: templatePath,
                    catalog: bucket.catalog,
                    language: bucket.language,
                    disambiguate: buckets.count > 1
                )
                try TranslationPayload.writeTemplate(
                    keys: keys,
                    catalog: bucket.catalog,
                    language: bucket.language,
                    to: workspace.configuration.absolute(path)
                )
                report.templatesWritten.append(path)
            }
        }
        return report
    }

    private func analyze(_ catalog: Catalog) throws -> CatalogReport {
        let keys = catalog.keys.sorted()
        let languages = try workspace.languages(for: catalog, requested: options.languages)

        var staleKeys: [String] = []
        var untranslatable: [String] = []
        var doNotTranslate: [String] = []
        var translatable: [String] = []

        for key in keys {
            if catalog.extractionState(key) == .stale {
                staleKeys.append(key)
                continue    // Xcode is retiring this string; do not demand work on it
            }
            if !catalog.shouldTranslate(key) {
                doNotTranslate.append(key)
                continue
            }
            if !KeyHeuristics.isTranslatable(key) {
                untranslatable.append(key)
                continue
            }
            translatable.append(key)
        }

        var coverage: [LanguageCoverage] = []
        var pluralGaps: [PluralGap] = []
        var formatMismatches: [FormatMismatch] = []

        for language in languages {
            let isSource = language == catalog.sourceLanguage
            var missing: [String] = []
            var empty: [String] = []
            var needsReview: [String] = []
            var identical: [String] = []
            var translated = 0

            for key in translatable {
                let status = catalog.status(key, language)
                switch status {
                case .missing:
                    // In the source language the key itself is the string.
                    if isSource { translated += 1 } else { missing.append(key) }
                case .empty:
                    if isSource { translated += 1 } else { empty.append(key) }
                case .unit(let state):
                    // In the source language the value is the string itself;
                    // Xcode writes `new` for extracted-with-value keys and means
                    // nothing by it.
                    if isSource || state.countsAsTranslated {
                        translated += 1
                    } else {
                        missing.append(key)
                    }
                    if !isSource, status.needsReview { needsReview.append(key) }
                case .variations(let missingCategories):
                    if missingCategories.isEmpty {
                        translated += 1
                    } else {
                        pluralGaps.append(PluralGap(
                            key: key,
                            language: language,
                            missingCategories: missingCategories
                        ))
                    }
                }

                guard !isSource else { continue }

                // The source string is the source-language value when there is
                // one. Plenty of projects use identifier keys —
                // "notifications.label.favorite %lld" whose English value is
                // "starred" — and comparing a translation against the key then
                // compares it against something no user ever sees.
                let sourceString = catalog.value(key, catalog.sourceLanguage) ?? key

                if let value = catalog.value(key, language), value == sourceString, sourceString.count > 3 {
                    identical.append(key)
                }
                let declaredSpecifiers = catalog.substitutionSpecifiers(key, language)
                let sourceEntries = Dictionary(
                    catalog.comparableEntries(key, catalog.sourceLanguage),
                    uniquingKeysWith: { first, _ in first }
                )
                for (path, value) in catalog.comparableEntries(key, language) {
                    // Empty values are already reported as missing work.
                    guard !value.isEmpty else { continue }
                    // A variation is compared against the same variation in the
                    // source language; with no counterpart there is nothing
                    // trustworthy to compare against.
                    guard let counterpart = sourceEntries[path] ?? (path.isEmpty ? sourceString : nil) else {
                        continue
                    }
                    if let problem = FormatSpecifierScanner.mismatch(
                        source: counterpart,
                        translation: value,
                        substitutions: declaredSpecifiers
                    ) {
                        formatMismatches.append(FormatMismatch(
                            key: key,
                            language: language,
                            problem: path.isEmpty ? problem : "[\(path)] \(problem)"
                        ))
                        break   // one report per key and language is enough
                    }
                }
                for problem in catalog.substitutionProblems(key, language) {
                    formatMismatches.append(FormatMismatch(key: key, language: language, problem: problem))
                }
            }

            coverage.append(LanguageCoverage(
                language: language,
                translatable: translatable.count,
                translated: translated,
                missing: missing.sorted(),
                empty: empty.sorted(),
                needsReview: needsReview.sorted(),
                identicalToSource: identical.sorted(),
                isSourceLanguage: isSource
            ))
        }

        let similar = catalog.kind.wantsSimilarKeyCheck
            ? SimilarKeys.similar(
                keys: keys,
                threshold: workspace.configuration.similarityThreshold,
                ignored: workspace.configuration.ignoredSimilarPairs
            )
            : []

        return CatalogReport(
            path: catalog.displayPath,
            table: catalog.kind.displayName,
            sourceLanguage: catalog.sourceLanguage,
            keyCount: keys.count,
            translatableCount: translatable.count,
            staleKeys: staleKeys,
            untranslatableKeys: untranslatable,
            doNotTranslateKeys: doNotTranslate,
            coverage: coverage,
            caseDuplicates: SimilarKeys.caseDuplicates(in: catalog),
            similarKeys: similar,
            pluralGaps: pluralGaps,
            formatMismatches: formatMismatches
        )
    }
}
