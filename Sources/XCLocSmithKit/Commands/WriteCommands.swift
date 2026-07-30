import Foundation

/// Applies a payload of translations to one catalog.
public struct AddCommand {
    public struct Options {
        public var languages: [String]
        public var state: TranslationState
        public var flatten: Bool
        public var dryRun: Bool
        public var allowNewLanguage: Bool
        public var createKeys: Bool

        public init(
            languages: [String] = [],
            state: TranslationState = .translated,
            flatten: Bool = false,
            dryRun: Bool = false,
            allowNewLanguage: Bool = false,
            createKeys: Bool = true
        ) {
            self.languages = languages
            self.state = state
            self.flatten = flatten
            self.dryRun = dryRun
            self.allowNewLanguage = allowNewLanguage
            self.createKeys = createKeys
        }
    }

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run(payload: TranslationPayload, catalogPath: String?) throws -> WriteReport {
        // The payload names its own catalog and language, so a template applied
        // as-is cannot land in the wrong file.
        if let catalogPath, let declared = payload.catalog,
           (catalogPath as NSString).lastPathComponent != (declared as NSString).lastPathComponent {
            throw SmithError.usage(
                "this payload is for \(declared) but \(catalogPath) was given; "
                + "remove the argument to use the payload's own catalog"
            )
        }
        let path = catalogPath ?? payload.catalog
        guard let path else {
            throw SmithError.usage("no catalog given: pass one, or use a template that names it")
        }
        guard var catalog = workspace.catalog(at: path) else {
            throw SmithError.cannotRead(path: path, reason: "not a readable catalog")
        }

        let requested = options.languages.isEmpty
            ? [payload.language].compactMap { $0 }
            : options.languages
        let language = try workspace.writeLanguage(
            for: catalog,
            requested: requested,
            allowUnknown: options.allowNewLanguage
        )

        var report = WriteReport(catalog: catalog.displayPath, language: language)
        report.dryRun = options.dryRun

        // Track keys added during this run too, so a payload containing both
        // "Save" and "save" cannot slip two colliding keys into the catalog.
        var byLowercase: [String: String] = [:]
        for key in catalog.keys { byLowercase[key.lowercased()] = key }

        for key in payload.entries.keys.sorted() {
            guard let entry = payload.entries[key] else { continue }

            if entry.isTodo {
                report.changes.append(.init(key: key, action: .skipped, detail: "still TODO"))
                continue
            }

            let isNew = !catalog.contains(key)
            if isNew {
                guard options.createKeys else {
                    report.refusals.append(.init(key: key, reason: "not in the catalog and --create was not given"))
                    continue
                }
                if let existing = byLowercase[key.lowercased()], existing != key {
                    report.conflicts.append((key: key, existing: existing))
                    continue
                }
                // No extractionState: the key is presumed to come from source and
                // stay under the build's management. Stamping "manual" on
                // everything is what makes a catalog drift out of sync.
                catalog.register(key, extractionState: nil)
                byLowercase[key.lowercased()] = key
                report.changes.append(.init(key: key, action: .registered))
            }

            switch entry {
            case .simple(let value):
                try apply(value: value, key: key, language: language, state: options.state,
                          catalog: &catalog, report: &report)

            case .detailed(let value, let state, let comment):
                if let comment { catalog.setComment(comment, for: key) }
                try apply(value: value, key: key, language: language, state: state ?? options.state,
                          catalog: &catalog, report: &report)

            case .plural(let forms):
                do {
                    for category in forms.keys.sorted() {
                        guard let value = forms[category], value != TranslationPayload.todoMarker else { continue }
                        try catalog.setPluralTranslation(
                            key: key,
                            language: language,
                            category: category,
                            value: value,
                            state: options.state,
                            flatten: options.flatten
                        )
                    }
                    report.changes.append(.init(
                        key: key,
                        action: .translated,
                        detail: "plural: \(forms.keys.sorted().joined(separator: ", "))"
                    ))
                } catch let error as SmithError {
                    guard case .wouldDiscardStructure(_, _, let structure) = error else { throw error }
                    report.refusals.append(.init(key: key, reason: "holds \(structure); pass --flatten to overwrite"))
                }
            }
        }

        if !options.dryRun, report.changes.contains(where: { $0.action != WriteReport.Action.skipped.rawValue }) {
            try workspace.save(catalog)
        }
        return report
    }

    private func apply(
        value: String,
        key: String,
        language: String,
        state: TranslationState,
        catalog: inout Catalog,
        report: inout WriteReport
    ) throws {
        do {
            let existed = try catalog.setTranslation(
                key: key,
                language: language,
                value: value,
                state: state,
                flatten: options.flatten
            )
            report.changes.append(.init(key: key, action: existed ? .updated : .translated))
        } catch let error as SmithError {
            guard case .wouldDiscardStructure(_, _, let structure) = error else { throw error }
            report.refusals.append(.init(key: key, reason: "holds \(structure); pass --flatten to overwrite"))
        }
    }
}

/// Sets a single translation.
public struct SetCommand {
    private let workspace: Workspace
    private let options: AddCommand.Options

    public init(workspace: Workspace, options: AddCommand.Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run(key: String, value: String, catalogPath: String?) throws -> WriteReport {
        guard let path = catalogPath ?? singleCatalogPath() else {
            throw SmithError.ambiguousCatalog(candidates: workspace.targets.flatMap(\.catalogs))
        }
        guard var catalog = workspace.catalog(at: path) else {
            throw SmithError.cannotRead(path: path, reason: "not a readable catalog")
        }
        let language = try workspace.writeLanguage(
            for: catalog,
            requested: options.languages,
            allowUnknown: options.allowNewLanguage
        )

        var report = WriteReport(catalog: catalog.displayPath, language: language)
        report.dryRun = options.dryRun

        if !catalog.contains(key) {
            // Creating a key by typo is silent and permanent, so it is opt-in.
            guard options.createKeys else {
                throw SmithError.keyNotFound(key, catalog: catalog.displayPath)
            }
            let variants = SimilarKeys.caseVariants(of: key, in: catalog.keys)
            if let existing = variants.first {
                report.conflicts.append((key: key, existing: existing))
                return report
            }
            catalog.register(key, extractionState: .manual)
            report.changes.append(.init(key: key, action: .registered))
        }

        let existed = try catalog.setTranslation(
            key: key,
            language: language,
            value: value,
            state: options.state,
            flatten: options.flatten
        )
        report.changes.append(.init(key: key, action: existed ? .updated : .translated))

        if !options.dryRun { try workspace.save(catalog) }
        return report
    }

    private func singleCatalogPath() -> String? {
        let all = workspace.targets.flatMap(\.catalogs)
        return all.count == 1 ? all[0] : nil
    }
}

/// Removes keys no source file references.
public struct PruneCommand {
    public struct Options {
        public var dryRun: Bool
        public var force: Bool
        public var includeFormatKeys: Bool

        public init(dryRun: Bool = true, force: Bool = false, includeFormatKeys: Bool = false) {
            self.dryRun = dryRun
            self.force = force
            self.includeFormatKeys = includeFormatKeys
        }
    }

    /// Refuse to remove more than this share of a catalog without --force: a
    /// number that high nearly always means a source directory is missing from
    /// the configuration, not that the catalog is mostly dead.
    static let refusalRatio = 0.25

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run() throws -> [WriteReport] {
        var scan = ScanCommand(
            workspace: workspace,
            options: .init(writeTemplates: false, includeFormatKeysInOrphans: options.includeFormatKeys)
        )
        let scanReport = try scan.run()

        // Decide everything before writing anything: a partial prune behind an
        // exit code that says "refused" is worse than either outcome alone.
        var planned: [(catalog: Catalog, keys: [String], report: WriteReport)] = []
        var seenCatalogs = Set<String>()
        for orphan in scanReport.orphans {
            // Orphans are computed per catalog, but guard against ever planning
            // the same file twice: two plans would be saved from two copies and
            // the last write would silently undo the first.
            guard seenCatalogs.insert(orphan.catalog).inserted else { continue }
            guard var catalog = workspace.catalog(at: orphan.catalog) else { continue }
            var report = WriteReport(catalog: catalog.displayPath)
            report.dryRun = options.dryRun

            let ratio = Double(orphan.keys.count) / Double(max(catalog.keys.count, 1))
            if ratio > Self.refusalRatio && !options.force {
                let percent = Int(ratio * 100)
                report.refusals = orphan.keys.map {
                    .init(key: $0, reason: "would remove \(percent)% of this catalog; pass --force if that is intended")
                }
                planned.append((catalog, [], report))
                continue
            }
            for key in orphan.keys { report.changes.append(.init(key: key, action: .removed)) }
            planned.append((catalog, orphan.keys, report))
        }

        guard !planned.contains(where: { !$0.report.refusals.isEmpty }) else {
            return planned.map(\.report)
        }

        if !options.dryRun {
            for entry in planned where !entry.keys.isEmpty {
                var catalog = entry.catalog
                for key in entry.keys { catalog.remove(key) }
                try workspace.save(catalog)
            }
        }
        return planned.map(\.report)
    }
}


