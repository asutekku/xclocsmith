import Foundation

/// Finds user-visible strings in source and checks them against the catalogs
/// that the code can actually reach.
public struct ScanCommand {
    public struct Options {
        public var languages: [String]
        public var writeTemplates: Bool
        public var templatePath: String?
        public var includeFormatKeysInOrphans: Bool

        public init(
            languages: [String] = [],
            writeTemplates: Bool = false,
            templatePath: String? = nil,
            includeFormatKeysInOrphans: Bool = false
        ) {
            self.languages = languages
            self.writeTemplates = writeTemplates
            self.templatePath = templatePath
            self.includeFormatKeysInOrphans = includeFormatKeysInOrphans
        }
    }

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run() throws -> ScanReport {
        var report = ScanReport()
        let configuration = workspace.configuration

        // One pass over every target's compiled sources.
        var perTarget: [(target: Target, files: [AnalyzedSource])] = []
        var allFiles: [String: AnalyzedSource] = [:]
        for target in workspace.targets {
            let files = workspace.sources(in: target.sources)
            for file in files { allFiles[file.path] = file }
            perTarget.append((target, files))
        }
        guard !allFiles.isEmpty else {
            throw SmithError.noSources(catalog: workspace.targets.first?.catalogs.first ?? "?")
        }

        let orderedFiles = allFiles.values.sorted { $0.path < $1.path }
        let discovered = LocalizableDiscovery.discover(in: orderedFiles)
        report.filesScanned = orderedFiles.count
        report.discoveredParameters = discovered.parameterOwners.mapValues { $0.sorted() }

        // Analyze each file once; results are reused per owning target.
        var analyzed: [String: SourceScanResult] = [:]
        for file in orderedFiles {
            analyzed[file.path] = SourceAnalyzer.analyze(
                file: file,
                discovered: discovered,
                options: configuration.classifierOptions,
                includePreviews: configuration.scanPreviews,
                ignoredStrings: configuration.ignoredStrings
            )
        }

        // Resolved once, before any scanning: a typo in --lang must fail the
        // run, not silently disable the untranslated check and report clean.
        var languagesByCatalog: [String: [String]] = [:]
        for target in workspace.targets {
            for catalog in workspace.catalogs(for: target) {
                guard languagesByCatalog[catalog.path] == nil else { continue }
                languagesByCatalog[catalog.path] = try workspace.languages(
                    for: catalog,
                    requested: options.languages
                )
            }
        }

        var missing: [MissingKeyFinding] = []
        var untranslated: [UntranslatedFinding] = []
        var bypasses: [BypassWarning] = []
        var stringCount = 0

        for (target, files) in perTarget {
            for file in files {
                guard let result = analyzed[file.path] else { continue }
                bypasses.append(contentsOf: result.bypasses)
                if result.hasDynamicTables { report.hasDynamicTables = true }

                for found in result.strings {
                    stringCount += 1

                    // Resolve the table the call asked for. A key in Errors.xcstrings
                    // does not satisfy a lookup in Localizable.xcstrings.
                    guard let catalog = workspace.catalog(for: found.table, in: target) else {
                        missing.append(MissingKeyFinding(
                            value: found.value,
                            file: found.file,
                            line: found.line,
                            context: found.context,
                            catalog: "\(found.table ?? "Localizable").xcstrings (no such table in \(target.name))",
                            table: found.table ?? "Localizable",
                            isFormatKey: found.isFormatKey
                        ))
                        continue
                    }

                    guard let key = resolveKey(found, in: catalog) else {
                        missing.append(MissingKeyFinding(
                            value: found.value,
                            file: found.file,
                            line: found.line,
                            context: found.context,
                            catalog: catalog.displayPath,
                            table: catalog.kind.displayName,
                            isFormatKey: found.isFormatKey
                        ))
                        continue
                    }

                    guard catalog.shouldTranslate(key) else { continue }
                    let languages = languagesByCatalog[catalog.path] ?? []
                    for language in languages where language != catalog.sourceLanguage {
                        if !catalog.status(key, language).isComplete {
                            untranslated.append(UntranslatedFinding(
                                value: key,
                                file: found.file,
                                line: found.line,
                                context: found.context,
                                catalog: catalog.displayPath,
                                language: language
                            ))
                        }
                    }
                }
            }
        }

        report.stringsFound = stringCount
        report.missingKeys = dedupe(missing)
        report.untranslated = dedupeUntranslated(untranslated)
        report.bypasses = bypasses.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        report.orphans = orphans(perTarget: perTarget, analyzed: analyzed)
        report.diagnostics = workspace.diagnostics

        if options.writeTemplates {
            report.templatesWritten = try writeTemplates(for: report)
        }
        return report
    }

    /// An interpolated literal becomes a format key; match it against the
    /// catalog by pattern since the specifier types are not knowable statically.
    private func resolveKey(_ found: FoundString, in catalog: Catalog) -> String? {
        if catalog.contains(found.value) { return found.value }
        guard found.isFormatKey, let pattern = found.formatPattern,
              let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return nil }
        for key in catalog.keys where FormatSpecifierScanner.containsSpecifier(key) {
            let range = NSRange(key.startIndex..., in: key)
            if let match = regex.firstMatch(in: key, range: range), match.range == range { return key }
        }
        return nil
    }

    private func dedupe(_ findings: [MissingKeyFinding]) -> [MissingKeyFinding] {
        var seen = Set<String>()
        return findings
            .filter { seen.insert("\($0.catalog)\u{1}\($0.value)").inserted }
            .sorted { ($0.catalog, $0.value) < ($1.catalog, $1.value) }
    }

    private func dedupeUntranslated(_ findings: [UntranslatedFinding]) -> [UntranslatedFinding] {
        var seen = Set<String>()
        return findings
            .filter { seen.insert("\($0.catalog)\u{1}\($0.language)\u{1}\($0.value)").inserted }
            .sorted { ($0.catalog, $0.language, $0.value) < ($1.catalog, $1.language, $1.value) }
    }

    /// Catalog keys nothing references.
    ///
    /// References are accumulated **per catalog**, not per target. A catalog
    /// listed by two targets — an app and its widget sharing one
    /// `Localizable.xcstrings` — is referenced by the union of both targets'
    /// sources. Computing it per target makes every app-only key look orphaned
    /// from the widget's side, and prune then deletes live keys.
    ///
    /// A target's `referenceSources` and non-Swift files count too, because a
    /// false orphan gets a live key deleted.
    private func orphans(
        perTarget: [(target: Target, files: [AnalyzedSource])],
        analyzed: [String: SourceScanResult]
    ) -> [OrphanFinding] {
        struct Accumulator {
            var catalog: Catalog
            var referenced = Set<String>()
            var patterns = Set<String>()
            var searchRoots: [String] = []
        }
        var byCatalog: [String: Accumulator] = [:]

        for (target, files) in perTarget {
            var referenced = Set<String>()
            var patterns = Set<String>()
            for file in files {
                guard let result = analyzed[file.path] else { continue }
                referenced.formUnion(result.referencedValues)
                patterns.formUnion(result.formatPatterns)
            }
            for file in workspace.sources(in: target.referenceSources) {
                let result = SourceAnalyzer.analyze(
                    file: file,
                    discovered: DiscoveredLocalizables(),
                    options: workspace.configuration.classifierOptions,
                    includePreviews: true,
                    ignoredStrings: []
                )
                referenced.formUnion(result.referencedValues)
                patterns.formUnion(result.formatPatterns)
            }

            for catalog in workspace.catalogs(for: target) {
                guard catalog.kind.isReferencedFromSource else { continue }
                var accumulator = byCatalog[catalog.path] ?? Accumulator(catalog: catalog)
                accumulator.referenced.formUnion(referenced)
                accumulator.patterns.formUnion(patterns)
                accumulator.searchRoots.append(contentsOf: target.sources + target.referenceSources)
                byCatalog[catalog.path] = accumulator
            }
        }

        var findings: [OrphanFinding] = []
        for path in byCatalog.keys.sorted() {
            guard let accumulator = byCatalog[path] else { continue }
            let catalog = accumulator.catalog
            let compiled = accumulator.patterns.compactMap {
                try? NSRegularExpression(pattern: "^" + $0 + "$")
            }

            var candidates: [String] = []
            for key in catalog.keys {
                guard KeyHeuristics.isTranslatable(key) else { continue }
                if catalog.extractionState(key) == .stale { continue }
                if accumulator.referenced.contains(key) { continue }
                if FormatSpecifierScanner.containsSpecifier(key) {
                    guard options.includeFormatKeysInOrphans else { continue }
                }
                let range = NSRange(key.startIndex..., in: key)
                let matched = compiled.contains { regex in
                    guard let match = regex.firstMatch(in: key, range: range) else { return false }
                    return match.range == range
                }
                if matched { continue }
                candidates.append(key)
            }

            if !candidates.isEmpty {
                let otherFiles = FileCollector.files(
                    in: Array(Set(accumulator.searchRoots)).sorted(),
                    configuration: workspace.configuration,
                    extensions: workspace.configuration.referenceExtensions
                )
                for filePath in otherFiles {
                    guard !candidates.isEmpty else { break }
                    guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
                    candidates = candidates.filter { !text.contains($0) }
                }
            }
            if !candidates.isEmpty {
                findings.append(OrphanFinding(catalog: catalog.displayPath, keys: candidates.sorted()))
            }
        }
        return findings
    }

    private func writeTemplates(for report: ScanReport) throws -> [String] {
        struct Bucket: Hashable {
            let catalog: String
            let language: String
        }
        var buckets: [Bucket: Set<String>] = [:]

        for finding in report.missingKeys where !finding.isFormatKey {
            // A key missing from the catalog needs the source language filled in
            // by Xcode extraction; the template targets the translation language.
            let language = workspace.configuration.languages.first ?? "und"
            buckets[Bucket(catalog: finding.catalog, language: language), default: []].insert(finding.value)
        }
        for finding in report.untranslated {
            buckets[Bucket(catalog: finding.catalog, language: finding.language), default: []].insert(finding.value)
        }
        guard !buckets.isEmpty else { return [] }

        var written: [String] = []
        for (bucket, keys) in buckets.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            let path = TemplateNaming.path(
                base: options.templatePath ?? "translations.json",
                catalog: bucket.catalog,
                language: bucket.language,
                disambiguate: buckets.count > 1
            )
            try TranslationPayload.writeTemplate(
                keys: keys.sorted(),
                catalog: bucket.catalog,
                language: bucket.language,
                to: workspace.configuration.absolute(path)
            )
            written.append(path)
        }
        return written
    }
}
