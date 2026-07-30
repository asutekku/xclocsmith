import Foundation

/// Shared loading and resolution for every command.
///
/// Catalogs are loaded once and parse failures are collected rather than
/// thrown: one corrupt file in a multi-catalog project should not deny you the
/// report for all the healthy ones.
public struct Workspace {
    public let configuration: Configuration
    public private(set) var diagnostics: [DiagnosticError] = []

    private var catalogCache: [String: Catalog] = [:]
    private var sourceCache: [String: AnalyzedSource] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var targets: [Target] { configuration.targets }

    // MARK: - Catalogs

    public mutating func catalog(at path: String) -> Catalog? {
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

    public mutating func catalogs(for target: Target) -> [Catalog] {
        target.catalogs.compactMap { catalog(at: $0) }
    }

    public mutating func allCatalogs() -> [Catalog] {
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
    public mutating func catalog(for table: String?, in target: Target) -> Catalog? {
        let wanted = table ?? "Localizable"
        for catalog in catalogs(for: target) where catalog.kind.tableName == wanted {
            return catalog
        }
        return nil
    }

    // MARK: - Sources

    public mutating func sources(in directories: [String]) -> [AnalyzedSource] {
        let paths = FileCollector.files(in: directories, configuration: configuration, extensions: ["swift"])
        var result: [AnalyzedSource] = []
        for path in paths {
            if let cached = sourceCache[path] {
                result.append(cached)
                continue
            }
            do {
                let source = try AnalyzedSource.load(path: path, displayPath: configuration.display(path))
                sourceCache[path] = source
                result.append(source)
            } catch {
                diagnostics.append(DiagnosticError(path: configuration.display(path), message: "\(error)"))
            }
        }
        return result
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
                    throw SmithError.unknownLanguage(language, known: present)
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
                throw SmithError.unknownLanguage(language, known: catalog.languages)
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
