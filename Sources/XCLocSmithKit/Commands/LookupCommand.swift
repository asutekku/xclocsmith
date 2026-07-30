import Foundation

/// Finds existing keys so a project does not grow three spellings of "Save".
public struct LookupCommand {
    private var workspace: Workspace
    private let languages: [String]

    public init(workspace: Workspace, languages: [String] = []) {
        self.workspace = workspace
        self.languages = languages
    }

    public mutating func run(queries: [String], catalogPaths: [String]?) throws -> LookupReports {
        let catalogs: [Catalog]
        if let catalogPaths {
            catalogs = catalogPaths.compactMap { workspace.catalog(at: $0) }
        } else {
            catalogs = workspace.allCatalogs()
        }

        var reports: [LookupReport] = []
        for query in queries {
            var report = LookupReport(query: query)
            for catalog in catalogs {
                report.matches.append(contentsOf: matches(for: query, in: catalog))
            }
            reports.append(report)
        }
        return LookupReports(reports: reports)
    }

    private func matches(for query: String, in catalog: Catalog) -> [LookupReport.Match] {
        let keys = catalog.keys
        let shown = (try? workspace.languages(for: catalog, requested: languages)) ?? catalog.languages

        func translations(_ key: String) -> [String: String] {
            var result: [String: String] = [:]
            for language in shown {
                if let value = catalog.value(key, language) { result[language] = value }
            }
            return result
        }

        if catalog.strings[query] != nil {
            return [.init(key: query, catalog: catalog.displayPath, kind: "exact",
                          similarity: 100, translations: translations(query))]
        }

        let variants = SimilarKeys.caseVariants(of: query, in: keys)
        if !variants.isEmpty {
            return variants.map {
                .init(key: $0, catalog: catalog.displayPath, kind: "caseVariant",
                      similarity: nil, translations: translations($0))
            }
        }

        var result: [LookupReport.Match] = []
        let lowered = query.lowercased()
        let contains = keys
            .filter { key in
                let key = key.lowercased()
                return key.contains(lowered) || (query.count >= 4 && lowered.contains(key) && key.count >= 4)
            }
            .sorted { ($0.count, $0) < ($1.count, $1) }
            .prefix(10)
        result.append(contentsOf: contains.map {
            .init(key: $0, catalog: catalog.displayPath, kind: "contains",
                  similarity: nil, translations: translations($0))
        })

        let queryCharacters = Array(lowered)
        let similar = keys
            .filter { $0.count >= 4 && $0.lowercased() != lowered && !contains.contains($0) }
            .compactMap { key -> (String, Int)? in
                let characters = Array(key.lowercased())
                let limit = Similarity.distanceLimit(
                    longest: max(characters.count, queryCharacters.count),
                    threshold: 70
                )
                let percent = Similarity.percent(queryCharacters, characters, limit: limit)
                return percent >= 70 ? (key, percent) : nil
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .prefix(8)
        result.append(contentsOf: similar.map {
            .init(key: $0.0, catalog: catalog.displayPath, kind: "similar",
                  similarity: $0.1, translations: translations($0.0))
        })

        return result
    }
}

/// Writes a configuration file describing the project.
public struct InitCommand {
    private let root: String
    private let force: Bool

    public init(root: String, force: Bool) {
        self.root = root
        self.force = force
    }

    public struct Result {
        public let path: String
        public let targets: [Target]
        public let languages: [String]
        /// Directories attached as reference-only sources, which the user may
        /// want to promote to compiled sources.
        public let sharedDirectories: [String]
    }

    public func run() throws -> Result {
        let path = URL(fileURLWithPath: root).appendingPathComponent(Configuration.fileName).path
        if FileManager.default.fileExists(atPath: path) && !force {
            throw SmithError.usage("\(Configuration.fileName) already exists (pass --force to overwrite)")
        }

        var configuration = Configuration(root: root)
        configuration.targets = try ProjectDiscovery.discoverTargets(
            root: root,
            excluded: configuration.excludedDirectories
        )

        var languages = Set<String>()
        for target in configuration.targets {
            for catalogPath in target.catalogs {
                guard let catalog = try? Catalog(path: configuration.absolute(catalogPath)) else { continue }
                languages.formUnion(catalog.languages.filter { $0 != catalog.sourceLanguage })
            }
        }
        configuration.languages = languages.sorted()

        do {
            try configuration.serialized().write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SmithError.cannotWrite(path: path, reason: error.localizedDescription)
        }

        let shared = Array(Set(configuration.targets.flatMap(\.referenceSources))).sorted()
        return Result(
            path: path,
            targets: configuration.targets,
            languages: configuration.languages,
            sharedDirectories: shared
        )
    }
}
