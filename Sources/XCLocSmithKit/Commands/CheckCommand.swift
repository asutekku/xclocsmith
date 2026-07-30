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
            var pluralisedByCatalog: [String: Set<String>] = [:]
            for catalogReport in report.catalogs {
                pluralisedByCatalog[catalogReport.path] = Set(catalogReport.pluralisedKeys)
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
                // The source string and the developer's comment are the whole
                // of the context a translator gets. Fetching them here costs a
                // cached catalog read and saves whoever fills this in from
                // guessing what an identifier key says.
                var sources: [String: String] = [:]
                var comments: [String: String] = [:]
                if let source = workspace.catalog(at: bucket.catalog) {
                    for key in keys {
                        if let text = source.displayText(key, source.sourceLanguage) {
                            sources[key] = text
                        }
                        if let comment = source.comment(key) { comments[key] = comment }
                    }
                }
                try TranslationPayload.writeTemplate(
                    keys: keys,
                    catalog: bucket.catalog,
                    language: bucket.language,
                    pluralKeys: pluralisedByCatalog[bucket.catalog] ?? [],
                    sources: sources,
                    comments: comments,
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

        // A variation gap the source language shares is one defect in the
        // string, not one per language: a device variation with no `other` case
        // is missing it in all 19 languages at once, and listing it 19 times
        // sends 18 translators after something only the source can fix. It is
        // reported here, once, against the source — which is often not even in
        // the checked set, so dropping it silently would lose it.
        let pluralisedInSource = Set(
            translatable.filter { catalog.isPluralised($0, catalog.sourceLanguage) }
        )

        var sourceVariationGaps: [String: [String]] = [:]
        for key in translatable {
            guard case .variations(let categories) = catalog.status(key, catalog.sourceLanguage),
                  !categories.isEmpty else { continue }
            sourceVariationGaps[key] = categories
            pluralGaps.append(PluralGap(
                key: key,
                language: catalog.sourceLanguage,
                missingCategories: categories
            ))
        }

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

                    // One string cannot serve four grammatical numbers. Where
                    // the source pluralises a key and the target language needs
                    // more than one form, a flat translation is incomplete — and
                    // it is what anyone filling in a template writes if nobody
                    // told them the key was a plural.
                    //
                    // Japanese is not caught: it requires `other` alone, so a
                    // flat string is exactly equivalent.
                    if !isSource, pluralisedInSource.contains(key) {
                        let required = PluralRules.categories(for: language).required
                        if required.count > 1 {
                            pluralGaps.append(PluralGap(
                                key: key,
                                language: language,
                                missingCategories: required
                            ))
                        }
                    }
                case .variations(let missingCategories):
                    if missingCategories.isEmpty {
                        translated += 1
                    } else {
                        // Already reported against the source. Categories a
                        // language genuinely needs — Russian `few` — are never
                        // gaps in English, so nothing real is hidden here.
                        let shared = Set(sourceVariationGaps[key] ?? [])
                        let unshared = missingCategories.filter { !shared.contains($0) }
                        if !unshared.isEmpty {
                            pluralGaps.append(PluralGap(
                                key: key,
                                language: language,
                                missingCategories: unshared
                            ))
                        }
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
                    // A category that stands for one known count may spell the
                    // number out and drop the specifier — English "%lld new
                    // post" is German "ein neuer Beitrag", and Arabic writes
                    // "بقي تكرار واحد" for "%lld Loop left". That is idiomatic,
                    // and it was 60 of the first 62 findings this comparison
                    // produced. `few`, `many` and `other` span unbounded counts,
                    // so they must carry the number.
                    guard !PluralRules.isExactCount(category: path) else { continue }
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
                            problem: path.isEmpty ? problem : "[\(path)] \(problem)",
                            source: counterpart,
                            translation: value
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
                // A key with no source text at all is not comparable — falling
                // back to the key would compare namespaces, not wording.
                entries: keys.compactMap { key in
                    catalog.displayText(key, catalog.sourceLanguage).map { (key, $0) }
                },
                threshold: workspace.configuration.similarityThreshold,
                ignored: workspace.configuration.ignoredSimilarPairs
            )
            : []

        let duplicates = catalog.kind.wantsSimilarKeyCheck
            ? Consistency.duplicateSources(
                in: catalog,
                languages: languages,
                ignored: workspace.configuration.ignoredSimilarPairs
            )
            : []

        let glossaryViolations = Consistency.glossaryViolations(
            in: catalog,
            glossary: workspace.configuration.glossary,
            keys: translatable,
            languages: languages
        )

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
            duplicateSources: duplicates,
            glossaryViolations: glossaryViolations,
            pluralGaps: pluralGaps,
            formatMismatches: formatMismatches,
            pluralisedKeys: pluralisedInSource.sorted()
        )
    }
}
