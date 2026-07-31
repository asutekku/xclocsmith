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

    /// Every user-visible string the scanner recognises, with the file, line
    /// and table each one resolves to.
    ///
    /// `run()` answers "which of these is a problem" and throws the rest away.
    /// `rename` needs the opposite: every call site that reaches one key,
    /// problem or not, because those are the literals it has to rewrite. Going
    /// through the scanner rather than searching for the text is what keeps it
    /// from touching a string that merely contains the key, or one belonging to
    /// another table.
    public func occurrences() throws -> [FoundString] {
        var files: [String: AnalyzedSource] = [:]
        for target in workspace.targets {
            for file in workspace.sources(in: target.sources) { files[file.path] = file }
        }
        // Test code is dropped here for the same reason it is in `run()`: a
        // literal in a test is not a call site anybody ships.
        let ordered = files.values.sorted { $0.path < $1.path }.filter { !$0.isTestCode }
        guard !ordered.isEmpty else { return [] }

        let discovered = LocalizableDiscovery.discover(in: ordered)
        return ordered.flatMap { file in
            SourceAnalyzer.analyze(
                file: file,
                discovered: discovered,
                options: workspace.configuration.classifierOptions,
                includePreviews: workspace.configuration.scanPreviews,
                ignoredStrings: workspace.configuration.ignoredStrings
            ).strings
        }
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
        // Which catalogs a table reaches depends on the target and the table,
        // never on the string. Asking per string rebuilt the project's whole
        // catalog list twenty-five thousand times.
        var reachableCache: [String: [Catalog]] = [:]

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
                        // Keyed by the target's own name, not by `targetKey`:
                        // an inferred target lists its own catalogs first, so
                        // two of them reach the same set in a different order.
                        let tableKey = "\(target.name)\u{1}\(table)"
                        let reachable: [Catalog]
                        if let cached = reachableCache[tableKey] {
                            reachable = cached
                        } else {
                            reachable = workspace.catalogs(for: found.table, reachableFrom: target)
                            reachableCache[tableKey] = reachable
                        }
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
            var searchRoots = Set<String>()
            /// Names the Swift file list this catalog is checked against, so
            /// catalogs sharing one list can share the pass over it.
            var searchedSwift: String?
        }
        var byCatalog: [String: Accumulator] = [:]
        var swiftLists: [String: [AnalyzedSource]] = [:]
        var globalReferenced = Set<String>()
        var globalPatterns = Set<String>()
        var globalSwift: [AnalyzedSource] = []

        // Reference sources are analyzed once per file and unioned once per
        // directory set. All twelve of DuckDuckGo's inferred targets name
        // `iOS`, so doing this inside the loop below read the same two thousand
        // files twelve times over — a third of the whole command, on one core.
        struct References {
            var referenced = Set<String>()
            var patterns = Set<String>()
        }
        let rootsKeys = perTarget.map { $0.target.referenceSources.joined(separator: "\u{1}") }
        var filesByRoots: [String: [AnalyzedSource]] = [:]
        for (index, entry) in perTarget.enumerated() where filesByRoots[rootsKeys[index]] == nil {
            filesByRoots[rootsKeys[index]] = workspace.sources(in: entry.target.referenceSources)
        }
        var distinctReferences: [AnalyzedSource] = []
        var seenPaths = Set<String>()
        for key in filesByRoots.keys.sorted() {
            for file in filesByRoots[key] ?? [] where seenPaths.insert(file.path).inserted {
                distinctReferences.append(file)
            }
        }
        let referenceResults = parallelMap(distinctReferences) { file in
            SourceAnalyzer.analyze(
                file: file,
                discovered: DiscoveredLocalizables(),
                options: workspace.configuration.classifierOptions,
                includePreviews: true,
                ignoredStrings: []
            )
        }
        var referenceAnalyzed: [String: SourceScanResult] = [:]
        referenceAnalyzed.reserveCapacity(distinctReferences.count)
        for (file, result) in zip(distinctReferences, referenceResults) {
            referenceAnalyzed[file.path] = result
        }
        var referencesByRoots: [String: References] = [:]
        for key in filesByRoots.keys.sorted() {
            var union = References()
            for file in filesByRoots[key] ?? [] {
                guard let result = referenceAnalyzed[file.path] else { continue }
                union.referenced.formUnion(result.referencedValues)
                union.patterns.formUnion(result.formatPatterns)
            }
            referencesByRoots[key] = union
        }

        for (index, entry) in perTarget.enumerated() {
            let (target, files) = entry
            var referenced = Set<String>()
            var patterns = Set<String>()
            for file in files {
                guard let result = analyzed[file.path] else { continue }
                referenced.formUnion(result.referencedValues)
                patterns.formUnion(result.formatPatterns)
            }
            if let union = referencesByRoots[rootsKeys[index]] {
                referenced.formUnion(union.referenced)
                patterns.formUnion(union.patterns)
            }

            for catalog in workspace.catalogs(for: target) {
                guard catalog.kind.isReferencedFromSource else { continue }
                var accumulator = byCatalog[catalog.path] ?? Accumulator(catalog: catalog)
                accumulator.referenced.formUnion(referenced)
                accumulator.patterns.formUnion(patterns)
                accumulator.searchRoots.formUnion(target.sources + target.referenceSources)
                // Only a non-empty list counts, so a target that compiles
                // nothing does not deny the catalog the evidence of one that
                // does.
                if accumulator.searchedSwift == nil, !files.isEmpty {
                    accumulator.searchedSwift = target.name
                    swiftLists[target.name] = files
                }
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
        let pooledSwiftKey = "\u{1}pooled"
        if workspace.targets.allSatisfy(\.inferred) {
            swiftLists[pooledSwiftKey] = globalSwift
            for path in byCatalog.keys {
                byCatalog[path]?.referenced.formUnion(globalReferenced)
                byCatalog[path]?.patterns.formUnion(globalPatterns)
                if byCatalog[path]?.searchedSwift == nil {
                    byCatalog[path]?.searchedSwift = globalSwift.isEmpty ? nil : pooledSwiftKey
                }
            }
        }

        // Every catalog in a project whose targets were inferred is handed the
        // same pooled patterns, so compiling them per catalog compiled the same
        // few thousand regexes nineteen times on DuckDuckGo.
        var compiledCache: [String: NSRegularExpression?] = [:]
        func compile(_ patterns: Set<String>) -> [NSRegularExpression] {
            patterns.compactMap { pattern in
                if let cached = compiledCache[pattern] { return cached }
                let regex = try? NSRegularExpression(pattern: "^" + pattern + "$")
                compiledCache[pattern] = regex
                return regex
            }
        }

        // Candidates for every catalog first, so the project's XIBs and plists
        // can be read once for all of them rather than once each.
        let orderedPaths = byCatalog.keys.sorted()
        struct Candidate {
            let key: String
            let bytes: [UInt8]
        }
        var candidatesByCatalog: [String: [Candidate]] = [:]
        for path in orderedPaths {
            guard let accumulator = byCatalog[path] else { continue }
            let catalog = accumulator.catalog
            let compiled = compile(accumulator.patterns)

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
            // Encoded once here, not once per file: the search below asks the
            // same question of a key thousands of times, and re-encoding it
            // every time was most of what the orphan check cost on a project
            // with many catalogs.
            candidatesByCatalog[path] = candidates.map { Candidate(key: $0, bytes: $0.scanBytes) }
        }

        // Catalogs that search the same roots read those files together.
        // Nineteen catalogs over three directories otherwise read the whole
        // non-Swift side of the project nineteen times.
        var byRoots: [String: (roots: [String], catalogs: [String])] = [:]
        for path in orderedPaths {
            guard let roots = byCatalog[path]?.searchRoots.sorted() else { continue }
            let key = roots.joined(separator: "\u{1}")
            byRoots[key, default: (roots, [])].catalogs.append(path)
        }
        for rootsKey in byRoots.keys.sorted() {
            guard let group = byRoots[rootsKey] else { continue }
            var live = group.catalogs.filter { !(candidatesByCatalog[$0]?.isEmpty ?? true) }
            guard !live.isEmpty else { continue }
            let otherFiles = workspace.files(
                in: group.roots,
                extensions: workspace.configuration.referenceExtensions
            )
            // `String.contains` goes through Foundation's canonical,
            // locale-aware search, which is grapheme-by-grapheme. Looking for a
            // few hundred keys in a project's XIBs and plists that way
            // dominated the whole command — four minutes of GoMap's four and a
            // half. A literal byte search asks the same question: is this exact
            // key mentioned anywhere.
            for filePath in otherFiles {
                guard !live.isEmpty else { break }
                guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
                var contents = text
                contents.withUTF8 { haystack in
                    for path in live {
                        candidatesByCatalog[path] = candidatesByCatalog[path]?
                            .filter { !ByteScan.contains($0.bytes, in: haystack) }
                    }
                }
                live = live.filter { !(candidatesByCatalog[$0]?.isEmpty ?? true) }
            }
        }

        // Last check: the Swift text itself. Deleting a key is irreversible,
        // so a key mentioned anywhere in the code is kept even when the
        // classifier could not attribute it — a `["save", "cancel"].map(localize)`
        // table, a `#if os(macOS)` branch, an idiom this tool has never seen.
        // Being wrong here costs a translator's work; being conservative costs
        // one line of advisory output.
        //
        // Grouped the same way, and for the same reason: HSTracker's
        // twenty-three catalogs are all checked against the one pooled file
        // list, and walking it per catalog was seven eighths of its runtime.
        var bySwiftList: [String: [String]] = [:]
        for path in orderedPaths {
            guard let key = byCatalog[path]?.searchedSwift else { continue }
            bySwiftList[key, default: []].append(path)
        }
        for listKey in bySwiftList.keys.sorted() {
            guard let group = bySwiftList[listKey] else { continue }
            var live = group.filter { !(candidatesByCatalog[$0]?.isEmpty ?? true) }
            for file in swiftLists[listKey] ?? [] {
                guard !live.isEmpty else { break }
                let filter = { (haystack: UnsafeBufferPointer<UInt8>) in
                    for path in live {
                        candidatesByCatalog[path] = candidatesByCatalog[path]?
                            .filter { !ByteScan.contains($0.bytes, in: haystack) }
                    }
                }
                // Contiguous for anything this tool read itself; the fallback
                // matters because skipping a file here would offer a live key
                // for deletion.
                if file.text.utf8.withContiguousStorageIfAvailable(filter) == nil {
                    Array(file.text.utf8).withUnsafeBufferPointer(filter)
                }
                live = live.filter { !(candidatesByCatalog[$0]?.isEmpty ?? true) }
            }
        }

        var findings: [OrphanFinding] = []
        for path in orderedPaths {
            guard let catalog = byCatalog[path]?.catalog,
                  let candidates = candidatesByCatalog[path], !candidates.isEmpty else { continue }
            findings.append(OrphanFinding(
                catalog: catalog.displayPath,
                keys: candidates.map(\.key).sorted()
            ))
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
