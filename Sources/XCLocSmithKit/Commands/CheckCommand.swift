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
        // Project-level checks run over whatever set was analysed, so
        // `check <one.xcstrings>` does not claim the other catalogs are missing
        // languages it was never asked to look at.
        if catalogPaths == nil {
            report.project.append(contentsOf: ProjectChecks.infoPlistCoverage(
                targets: workspace.targets,
                catalogs: catalogs,
                configuration: workspace.configuration
            ))
            report.project.append(contentsOf: ProjectChecks.developmentRegion(
                catalogs: catalogs,
                configuration: workspace.configuration
            ))
            report.project.append(contentsOf: ProjectChecks.languageCoverage(catalogs))
            // Inferred targets share source directories, so one Info.plist is
            // otherwise found once per target that happens to contain it.
            var seenProject = Set<String>()
            report.project = report.project.filter {
                seenProject.insert("\($0.rule.rawValue)\u{1}\($0.detail)").inserted
            }
        }
        report.diagnostics = workspace.diagnostics

        if let templatePath = options.templatePath {
            let templates = self.templates(for: report)
            for template in templates {
                let path = TemplateNaming.path(
                    base: templatePath,
                    catalog: template.catalog,
                    language: template.language,
                    disambiguate: templates.count > 1
                )
                let absolute = workspace.configuration.absolute(path)
                do {
                    try JSONWriter.text(template.document, style: .plain)
                        .write(toFile: absolute, atomically: true, encoding: .utf8)
                } catch {
                    throw SmithError.cannotWrite(path: absolute, reason: error.localizedDescription)
                }
                report.templatesWritten.append(path)
            }
        }
        return report
    }

    /// A fill-in template, one per catalog and language with work outstanding.
    ///
    /// Pooling them would attribute every key to the first catalog and the
    /// first language, and `add` would then create them in the wrong file.
    ///
    /// Shared with the MCP server, which returns these to a model instead of
    /// writing them: the decision about what shape a language needs — four
    /// plural rows for Russian, one for Japanese — belongs in one place, not in
    /// whatever the caller happens to remember.
    public func templates(for report: CheckReport) -> [Template] {
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

        return buckets.sorted(by: { "\($0.key)" < "\($1.key)" }).map { bucket, keys in
            // The source string and the developer's comment are the whole of
            // the context a translator gets. Fetching them here costs a cached
            // catalog read and saves whoever fills this in from guessing what
            // an identifier key says.
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
            return Template(
                catalog: bucket.catalog,
                language: bucket.language,
                keys: keys,
                document: TranslationPayload.makeTemplate(
                    keys: keys,
                    catalog: bucket.catalog,
                    language: bucket.language,
                    pluralKeys: pluralisedByCatalog[bucket.catalog] ?? [],
                    sources: sources,
                    comments: comments
                )
            )
        }
    }

    public struct Template {
        public let catalog: String
        public let language: String
        public let keys: [String]
        public let document: JSONValue
    }

    private func dedupe(_ findings: [HygieneFinding]) -> [HygieneFinding] {
        var seen = Set<String>()
        return findings.filter {
            seen.insert("\($0.rule.rawValue)\u{1}\($0.key)\u{1}\($0.language)").inserted
        }
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
        var hygiene: [HygieneFinding] = []

        // Source-side hygiene is about the English you wrote, so it is checked
        // once per key rather than once per key per language.
        for key in translatable {
            // In a literal-keyed catalog the key is the English, and no
            // source-language unit is written — the same fallback coverage uses.
            let text = catalog.displayText(key, catalog.sourceLanguage) ?? key
            hygiene.append(contentsOf: Hygiene.checkSource(
                key: key,
                source: text,
                language: catalog.sourceLanguage
            ))
        }

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
                // Mechanical comparison against the source string: punctuation,
                // spacing, invisible characters, broken markup. Compared on the
                // text a user sees, so a plural is compared category by
                // category rather than through one representative form.
                let sourceEntriesForHygiene = catalog.signature(key, catalog.sourceLanguage)
                for (path, translated) in catalog.signature(key, language).sorted(by: { $0.key < $1.key }) {
                    guard let counterpart = sourceEntriesForHygiene[path]
                        ?? (path.isEmpty ? sourceString : nil) else { continue }
                    hygiene.append(contentsOf: Hygiene.check(
                        key: key,
                        source: counterpart,
                        translation: translated,
                        language: language
                    ))
                }
                if let same = Hygiene.samePlurals(key: key, catalog: catalog, language: language) {
                    hygiene.append(same)
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
            sentenceKeys: KeyStyle.sentenceKeys(in: catalog),
            similarKeys: similar,
            duplicateSources: duplicates,
            glossaryViolations: glossaryViolations,
            // One finding per rule per key per language: a trailing space in
            // both `plural.one` and `plural.other` is one defect to fix, and
            // billing it per variation makes a six-category Arabic plural six
            // times as loud as a flat string with the same problem.
            hygiene: dedupe(hygiene),
            pluralGaps: pluralGaps,
            formatMismatches: formatMismatches,
            pluralisedKeys: pluralisedInSource.sorted()
        )
    }
}
