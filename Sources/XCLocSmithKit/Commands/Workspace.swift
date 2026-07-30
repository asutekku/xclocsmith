import Foundation

/// Shared loading and resolution for every command.
///
/// Catalogs are loaded once and parse failures are collected rather than
/// thrown: one corrupt file in a multi-catalog project should not deny you the
/// report for all the healthy ones.
///
/// A reference type, so a long-lived embedder (an MCP server, say) keeps one
/// workspace across calls instead of re-parsing the project every time — and so
/// a write can invalidate what the cache holds. As a value type the caches were
/// copied into each command and a write-then-read sequence returned the
/// pre-write catalog. Not thread-safe: use one workspace per unit of work.
public final class Workspace {
    public let configuration: Configuration
    public private(set) var diagnostics: [DiagnosticError] = []

    private var catalogCache: [String: Catalog] = [:]
    private var sourceCache: [String: AnalyzedSource] = [:]
    private var sourceListCache: [String: [AnalyzedSource]] = [:]
    private var fileListCache: [String: [String]] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var targets: [Target] { configuration.targets }

    // MARK: - Catalogs

    public func catalog(at path: String) -> Catalog? {
        let absolute = configuration.absolute(path)
        if let cached = catalogCache[absolute] { return cached }
        do {
            let catalog = try Catalog(path: absolute, displayPath: configuration.display(absolute))
            catalogCache[absolute] = catalog
            return catalog
        } catch {
            diagnostics.append(DiagnosticError(
                path: configuration.display(absolute),
                message: "\(error)"
            ))
            return nil
        }
    }

    public func catalogs(for target: Target) -> [Catalog] {
        target.catalogs.compactMap { catalog(at: $0) }
    }

    public func allCatalogs() -> [Catalog] {
        var seen = Set<String>()
        var result: [Catalog] = []
        for target in targets {
            for catalog in catalogs(for: target) where seen.insert(catalog.path).inserted {
                result.append(catalog)
            }
        }
        return result
    }

    /// The catalog a call site reaches, given the table it asked for.
    public func catalog(for table: String?, in target: Target) -> Catalog? {
        let wanted = table ?? "Localizable"
        for catalog in catalogs(for: target) where catalog.kind.tableName == wanted {
            return catalog
        }
        return nil
    }

    /// Every catalog in the project that serves this table, the target's own
    /// first.
    ///
    /// Used when the target was inferred from the directory layout. GoMap has
    /// thirteen catalog directories and one source tree; without the build
    /// settings, every file belongs to every target, so a string present only
    /// in the app's `Localizable` would be reported missing from the other
    /// twelve. The table rule still holds — an `Errors` lookup is only ever
    /// satisfied by an `Errors` catalog.
    public func catalogs(for table: String?, reachableFrom target: Target) -> [Catalog] {
        let wanted = table ?? "Localizable"
        var result = catalogs(for: target).filter { $0.kind.tableName == wanted }
        guard target.inferred else { return result }
        var seen = Set(result.map(\.path))
        for catalog in allCatalogs()
        where catalog.kind.tableName == wanted && seen.insert(catalog.path).inserted {
            result.append(catalog)
        }
        return result
    }

    // MARK: - Sources

    /// The Swift files under these directories, read and lexed.
    ///
    /// Memoized by directory set as well as by file, because a project whose
    /// targets were inferred asks the same question over and over: DuckDuckGo's
    /// twelve targets name three directories between them, and walking those
    /// trees again for each was a fifth of `scan`.
    public func sources(in directories: [String]) -> [AnalyzedSource] {
        let key = directories.joined(separator: "\u{1}")
        if let cached = sourceListCache[key] { return cached }

        let paths = files(in: directories, extensions: ["swift"])
        // Reading and lexing a file depends on nothing but that file, so the
        // ones not already in hand are done across cores. Failures are recorded
        // afterwards, in path order, so diagnostics do not depend on timing.
        let pending = paths.filter { sourceCache[$0] == nil }
        if !pending.isEmpty {
            let displayPaths = pending.map { configuration.display($0) }
            let loaded = parallelMap(Array(pending.indices)) { index in
                Result { try AnalyzedSource.load(path: pending[index], displayPath: displayPaths[index]) }
            }
            for (index, outcome) in loaded.enumerated() {
                switch outcome {
                case .success(let source):
                    sourceCache[source.path] = source
                case .failure(let error):
                    diagnostics.append(DiagnosticError(path: displayPaths[index], message: "\(error)"))
                }
            }
        }

        let result = paths.compactMap { sourceCache[$0] }
        sourceListCache[key] = result
        return result
    }

    /// Paths under these directories, memoized. Walking a tree the size of
    /// DuckDuckGo's takes long enough that asking twice is worth avoiding, and
    /// the orphan check asks once per catalog for the same roots.
    public func files(in directories: [String], extensions: Set<String>) -> [String] {
        let key = directories.joined(separator: "\u{1}")
            + "\u{2}" + extensions.sorted().joined(separator: "\u{1}")
        if let cached = fileListCache[key] { return cached }
        let result = FileCollector.files(in: directories, configuration: configuration, extensions: extensions)
        fileListCache[key] = result
        return result
    }

    /// Saves a catalog and refreshes what the cache holds for it, so a later
    /// read in the same workspace sees the write.
    public func save(_ catalog: Catalog) throws {
        try catalog.save()
        catalogCache[catalog.path] = catalog
    }

    /// Drops every cached catalog and source. Call after something outside this
    /// workspace has changed the files.
    public func invalidate() {
        catalogCache.removeAll()
        sourceCache.removeAll()
        sourceListCache.removeAll()
        fileListCache.removeAll()
    }

    // MARK: - Languages

    /// Languages to report on for a catalog.
    ///
    /// A language named in the configuration counts even when the catalog has
    /// no entries for it yet — otherwise a freshly added localization with zero
    /// translations reports as complete.
    public func languages(for catalog: Catalog, requested: [String], allowUnknown: Bool = false) throws -> [String] {
        let present = catalog.languages
        let declared = configuration.languages

        if requested.contains("all") {
            let all = Set(present).union(declared)
            return all.sorted()
        }

        if !requested.isEmpty {
            if !allowUnknown {
                for language in requested where !present.contains(language) && !declared.contains(language) {
                    throw SmithError.unknownLanguage(language, known: present, creatable: false)
                }
            }
            return requested
        }

        if !declared.isEmpty { return declared.sorted() }
        return present.filter { $0 != catalog.sourceLanguage }.sorted()
    }

    /// The single language a write command should target.
    public func writeLanguage(for catalog: Catalog, requested: [String], allowUnknown: Bool) throws -> String {
        if requested.count > 1 {
            throw SmithError.usage("--lang takes one language for this command (got \(requested.joined(separator: ", ")))")
        }
        if let language = requested.first {
            if language == "all" {
                throw SmithError.usage("--lang all cannot be used with a command that writes translations")
            }
            let known = Set(catalog.languages).union(configuration.languages)
            if !allowUnknown && !known.contains(language) {
                throw SmithError.unknownLanguage(language, known: catalog.languages, creatable: true)
            }
            return language
        }
        let candidates = configuration.languages.isEmpty
            ? catalog.languages.filter { $0 != catalog.sourceLanguage }
            : configuration.languages
        if candidates.count == 1 { return candidates[0] }
        throw SmithError.ambiguousLanguage(candidates: candidates.sorted())
    }
}
