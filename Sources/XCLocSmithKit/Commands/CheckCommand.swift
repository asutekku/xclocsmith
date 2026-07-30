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

    private var workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public mutating func run(catalogPaths: [String]? = nil) throws -> CheckReport {
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
            let outstanding = report.catalogs.flatMap { catalogReport in
                catalogReport.coverage
                    .filter { !$0.isSourceLanguage }
                    .flatMap { $0.missing + $0.empty }
            }
            if !outstanding.isEmpty, let first = report.catalogs.first {
                let language = report.catalogs
                    .flatMap { $0.coverage }
                    .first { !$0.isSourceLanguage }?
                    .language ?? "und"
                try TranslationPayload.writeTemplate(
                    keys: Array(Set(outstanding)).sorted(),
                    catalog: first.path,
                    language: language,
                    to: templatePath
                )
                report.templatesWritten.append(templatePath)
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
                    if state.countsAsTranslated { translated += 1 } else { missing.append(key) }
                    if status.needsReview { needsReview.append(key) }
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

                if let value = catalog.value(key, language), value == key, key.count > 3 {
                    identical.append(key)
                }
                for value in catalog.comparableValues(key, language) {
                    if let problem = FormatSpecifierScanner.mismatch(source: key, translation: value) {
                        formatMismatches.append(FormatMismatch(key: key, language: language, problem: problem))
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
