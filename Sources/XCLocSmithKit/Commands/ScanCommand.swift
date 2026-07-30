import Foundation

/// Finds user-visible strings in source and checks them against the catalogs
/// that the code can actually reach.
public struct ScanCommand {
    public struct Options {
        public var languages: [String]
        public var writeTemplates: Bool
        public var templatePath: String?
        public var includeFormatKeysInOrphans: Bool
        /// Report only these files. The rest of the project is still read, so
        /// the classifier keeps everything it has learned about the project's
        /// own idioms — a helper defined in another file still counts.
        public var files: [String]

        public init(
            languages: [String] = [],
            writeTemplates: Bool = false,
            templatePath: String? = nil,
            includeFormatKeysInOrphans: Bool = false,
            files: [String] = []
        ) {
            self.languages = languages
            self.writeTemplates = writeTemplates
            self.templatePath = templatePath
            self.includeFormatKeysInOrphans = includeFormatKeysInOrphans
            self.files = files
        }
    }

    /// Where a found string ended up: in a catalog under some key, absent from
    /// every catalog that serves its table, or asking for a table the project
    /// has no catalog for at all.
    private enum Resolution {
        case present(Catalog, String)
        case absent(Catalog)
        case noSuchTable
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

        // Test code is dropped before anything else looks at it. Discovery
        // included: a test helper declaring `title: String` would otherwise
        // teach the classifier that every `title:` in the project is a key.
        let allOrdered = allFiles.values.sorted { $0.path < $1.path }
        let orderedFiles = allOrdered.filter { !$0.isTestCode }
        report.testFilesSkipped = allOrdered.count - orderedFiles.count
        // Discovery reads the whole project even when the report will not.
        // What the classifier knows about a file depends on declarations
        // elsewhere: a `title:` parameter is display text because some other
        // file declares the type that receives it.
        let discovered = LocalizableDiscovery.discover(in: orderedFiles)
        report.discoveredParameters = discovered.parameterOwners.mapValues { $0.sorted() }

        let selection = resolveSelection(configuration: configuration)
        let subject = selection.map { selection in
            orderedFiles.filter { selection.resolved.keys.contains($0.path) }
        } ?? orderedFiles
        if let selection {
            report.limitedToFiles = selection.resolved.values.sorted()
            // A path that reached no file is worth saying out loud, but it is
            // not a failure: a hook fires on whatever was written, and a test
            // file or a README is a normal thing to be handed. Echoed back as
            // it was typed, since a path this tool could not place is not one
            // to restate in its own terms.
            let reached = Set(subject.map(\.path))
            report.unscannedFiles = selection.resolved
                .filter { !reached.contains($0.key) }
                .values
                .sorted()
        }
        report.filesScanned = subject.count

        // Analyze each file once; results are reused per owning target.
        // Independent per file, like the lexing, so it runs across cores.
        var results = [SourceScanResult?](repeating: nil, count: subject.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer
            DispatchQueue.concurrentPerform(iterations: subject.count) { index in
                slots[index] = SourceAnalyzer.analyze(
                    file: subject[index],
                    discovered: discovered,
                    options: configuration.classifierOptions,
                    includePreviews: configuration.scanPreviews,
                    ignoredStrings: configuration.ignoredStrings
                )
            }
        }
        var analyzed: [String: SourceScanResult] = [:]
        for (index, file) in subject.enumerated() {
            analyzed[file.path] = results[index]
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

        let stringsIndex = StringsIndex.build(
            root: configuration.root,
            configuration: configuration
        )
        report.legacyStringsFiles = stringsIndex.fileCount

        var missing: [MissingKeyFinding] = []
        var untranslated: [UntranslatedFinding] = []
        var bypasses: [BypassWarning] = []
        var stringCount = 0
        var regexCache: [String: NSRegularExpression?] = [:]
        var keyCache: [String: [String]] = [:]
        // Resolution depends on the target only through its catalog set, so an
        // inferred target — which reaches every catalog for the table — shares
        // one entry. Without this, a project whose source tree belongs to ten
        // inferred targets asked the same question ten times.
        var resolutionCache: [String: Resolution] = [:]

        // Each file is visited once per target that compiles it, because the
        // catalogs it may reach differ. Findings are keyed by file and line, so
        // a file in two targets is reported once, not twice.
        for (target, files) in perTarget {
            let targetKey = target.inferred ? "*" : target.name
            for file in files {
                guard let result = analyzed[file.path] else { continue }
                bypasses.append(contentsOf: result.bypasses)
                if result.hasDynamicTables { report.hasDynamicTables = true }

                for found in result.strings {
                    stringCount += 1
                    let table = found.table ?? "Localizable"
                    let cacheKey = "\(targetKey)\u{1}\(table)\u{1}\(found.value)"

                    let resolution: Resolution
                    if let cached = resolutionCache[cacheKey] {
                        resolution = cached
                    } else {
                        // Resolve the table the call asked for. A key in
                        // Errors.xcstrings does not satisfy a lookup in
                        // Localizable.xcstrings.
                        let reachable = workspace.catalogs(for: found.table, reachableFrom: target)
                        if reachable.isEmpty {
                            resolution = .noSuchTable
                        } else {
                            var found_: Resolution = .absent(reachable[0])
                            for candidate in reachable {
                                if let key = resolveKey(
                                    found, in: candidate,
                                    regexCache: &regexCache, keyCache: &keyCache
                                ) {
                                    found_ = .present(candidate, key)
                                    break
                                }
                            }
                            resolution = found_
                        }
                        resolutionCache[cacheKey] = resolution
                    }

                    switch resolution {
                    case .noSuchTable:
                        missing.append(MissingKeyFinding(
                            value: found.value,
                            file: found.file,
                            line: found.line,
                            context: found.context,
                            catalog: "\(table).xcstrings (no such table in \(target.name))",
                            table: table,
                            isFormatKey: found.isFormatKey
                        ))

                    case .absent(let first):
                        // A project that keeps some tables in `.strings` is not
                        // missing those keys; this tool just does not manage
                        // them. Reporting them would bury the real findings —
                        // on DuckDuckGo it was 20,323 of 29,932.
                        guard !stringsIndex.contains(found.value, table: found.table) else {
                            report.resolvedInLegacyStrings += 1
                            continue
                        }
                        missing.append(MissingKeyFinding(
                            value: found.value,
                            file: found.file,
                            line: found.line,
                            context: found.context,
                            catalog: first.displayPath,
                            table: first.kind.displayName,
                            isFormatKey: found.isFormatKey
                        ))

                    case .present(let catalog, let key):
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
        }

        report.stringsFound = stringCount
        report.missingKeys = dedupe(missing)
        report.untranslated = dedupeUntranslated(untranslated)
        // A file compiled into two targets produces its bypasses twice.
        var seenBypasses = Set<String>()
        report.bypasses = bypasses
            .filter { seenBypasses.insert("\($0.file)\u{1}\($0.line)\u{1}\($0.reason)").inserted }
            .sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        // A key is orphaned when *nothing* references it, which cannot be
        // concluded from a subset of the sources. Reporting it anyway would
        // offer live keys for deletion.
        if selection == nil {
            report.orphans = orphans(perTarget: perTarget, analyzed: analyzed)
        }
        report.diagnostics = workspace.diagnostics

        if options.writeTemplates {
            report.templatesWritten = try writeTemplates(for: report)
        }
        return report
    }

    /// The files `--files` named, keyed by absolute path and carrying the
    /// spelling they were given in. Nil for a whole-project run.
    ///
    /// A relative path is resolved against the working directory first, because
    /// that is where a person or a hook is standing when they type it; the
    /// configuration's root is the fallback, which is the same thing whenever
    /// the two agree.
    private struct Selection {
        /// absolute path → the argument that produced it
        var resolved: [String: String]
    }

    private func resolveSelection(configuration: Configuration) -> Selection? {
        guard !options.files.isEmpty else { return nil }
        let workingDirectory = FileManager.default.currentDirectoryPath
        var resolved: [String: String] = [:]
        for path in options.files {
            let absolute: String
            if path.hasPrefix("/") {
                absolute = URL(fileURLWithPath: path).standardized.path
            } else {
                let fromWorkingDirectory = URL(fileURLWithPath: workingDirectory)
                    .appendingPathComponent(path).standardized.path
                absolute = FileManager.default.fileExists(atPath: fromWorkingDirectory)
                    ? fromWorkingDirectory
                    : configuration.absolute(path)
            }
            resolved[absolute] = path
        }
        return Selection(resolved: resolved)
    }

    /// An interpolated literal becomes a format key; match it against the
    /// catalog by pattern since the specifier types are not knowable statically.
    ///
    /// The pattern walk is the one quadratic step in `scan` — every interpolated
    /// string against every specifier-bearing key. Both the compiled regex and
    /// each catalog's candidate keys are cached, because a large project asks
    /// the same question thousands of times: DuckDuckGo's 4,673 files took two
    /// and a half minutes without this, and seconds with it.
    private func resolveKey(
        _ found: FoundString,
        in catalog: Catalog,
        regexCache: inout [String: NSRegularExpression?],
        keyCache: inout [String: [String]]
    ) -> String? {
        if catalog.contains(found.value) { return found.value }
        guard found.isFormatKey, let pattern = found.formatPattern else { return nil }

        let regex: NSRegularExpression?
        if let cached = regexCache[pattern] {
            regex = cached
        } else {
            regex = try? NSRegularExpression(pattern: "^" + pattern + "$")
            regexCache[pattern] = regex
        }
        guard let regex else { return nil }

        let candidates: [String]
        if let cached = keyCache[catalog.path] {
            candidates = cached
        } else {
            candidates = catalog.keys.filter { FormatSpecifierScanner.containsSpecifier($0) }
            keyCache[catalog.path] = candidates
        }

        for key in candidates {
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
            var searchedSwift: [AnalyzedSource] = []
        }
        var byCatalog: [String: Accumulator] = [:]
        var globalReferenced = Set<String>()
        var globalPatterns = Set<String>()
        var globalSwift: [AnalyzedSource] = []

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
                if accumulator.searchedSwift.isEmpty { accumulator.searchedSwift = files }
                byCatalog[catalog.path] = accumulator
            }
            if target.inferred {
                globalReferenced.formUnion(referenced)
                globalPatterns.formUnion(patterns)
                globalSwift.append(contentsOf: files)
            }
        }

        // A guessed target owns a catalog directory, not a compilation unit.
        // HSTracker keeps its catalogs under `Translations/` and its code
        // elsewhere, so evidence gathered from the code never reached them and
        // 350 live keys were offered for deletion. Pool it.
        if workspace.targets.allSatisfy(\.inferred) {
            for path in byCatalog.keys {
                byCatalog[path]?.referenced.formUnion(globalReferenced)
                byCatalog[path]?.patterns.formUnion(globalPatterns)
                if byCatalog[path]?.searchedSwift.isEmpty == true {
                    byCatalog[path]?.searchedSwift = globalSwift
                }
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
                guard !KeyHeuristics.isInterfaceBuilderKey(key) else { continue }
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
                // `String.contains` goes through Foundation's canonical,
                // locale-aware search, which is grapheme-by-grapheme. Looking
                // for a few hundred keys in a project's XIBs and plists that
                // way dominated the whole command — four minutes of GoMap's
                // four and a half. A literal byte search asks the same
                // question: is this exact key mentioned anywhere.
                for filePath in otherFiles {
                    guard !candidates.isEmpty else { break }
                    guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
                    let haystack = Array(text.utf8)
                    candidates = candidates.filter { !containsBytes(of: $0, in: haystack) }
                }
            }

            // Last check: the Swift text itself. Deleting a key is
            // irreversible, so a key mentioned anywhere in the code is kept
            // even when the classifier could not attribute it — a
            // `["save", "cancel"].map(localize)` table, a `#if os(macOS)`
            // branch, an idiom this tool has never seen. Being wrong here
            // costs a translator's work; being conservative costs one line of
            // advisory output.
            if !candidates.isEmpty {
                for file in accumulator.searchedSwift {
                    guard !candidates.isEmpty else { break }
                    let haystack = Array(file.text.utf8)
                    candidates = candidates.filter { !containsBytes(of: $0, in: haystack) }
                }
            }
            if !candidates.isEmpty {
                findings.append(OrphanFinding(catalog: catalog.displayPath, keys: candidates.sorted()))
            }
        }
        return findings
    }

    /// Literal substring search over UTF-8, skipping ahead on the first byte.
    private func containsBytes(of needle: String, in haystack: [UInt8]) -> Bool {
        let pattern = Array(needle.utf8)
        guard let first = pattern.first, pattern.count <= haystack.count else {
            return pattern.isEmpty
        }
        let last = haystack.count - pattern.count
        var start = 0
        while start <= last {
            guard let offset = haystack[start...last].firstIndex(of: first) else { return false }
            if Array(haystack[offset..<(offset + pattern.count)]) == pattern { return true }
            start = offset + 1
        }
        return false
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
