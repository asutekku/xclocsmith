import Foundation

public struct XclocFinding: Equatable, Sendable {
    public let unitID: String
    public let file: String
    public let line: Int
    public let problem: String

    var jsonValue: JSONValue {
        .object([
            "unit": .string(unitID),
            "file": .string(file),
            "line": .number("\(line)"),
            "problem": .string(problem),
        ])
    }
}

public struct XclocCheckReport: Report {
    public var bundle: String
    public var targetLanguage: String?
    public var unitCount = 0
    public var translatedCount = 0

    /// Specifiers in the translation that disagree with the source — the defect
    /// that crashes at runtime rather than merely reading badly.
    public var formatMismatches: [XclocFinding] = []
    /// Plural categories the target language requires but the bundle omits.
    public var pluralGaps: [XclocFinding] = []
    /// Units the bundle carries whose key is in no catalog of this project.
    public var unknownKeys: [XclocFinding] = []
    /// Trans-unit id shapes this tool will not guess at.
    public var unsupportedUnits: [XclocFinding] = []
    /// Present but untranslated.
    public var untranslated: [XclocFinding] = []
    /// Machine translation, which should be reviewed before it ships.
    public var machineTranslated: [XclocFinding] = []
    /// Catalog keys this bundle never mentions.
    public var missingFromBundle: [String] = []
    public var metadataProblems: [String] = []

    public init(bundle: String, targetLanguage: String?) {
        self.bundle = bundle
        self.targetLanguage = targetLanguage
    }

    public var failures: Int {
        formatMismatches.count + pluralGaps.count + metadataProblems.count
    }

    public var advisories: Int {
        unknownKeys.count + unsupportedUnits.count + untranslated.count
            + machineTranslated.count + missingFromBundle.count
    }

    public var jsonValue: JSONValue {
        .object([
            "command": .string("xcloc check"),
            "bundle": .string(bundle),
            "targetLanguage": targetLanguage.map { JSONValue.string($0) } ?? .null,
            "units": .number("\(unitCount)"),
            "translated": .number("\(translatedCount)"),
            "formatMismatches": .array(formatMismatches.map(\.jsonValue)),
            "pluralGaps": .array(pluralGaps.map(\.jsonValue)),
            "unknownKeys": .array(unknownKeys.map(\.jsonValue)),
            "unsupportedUnits": .array(unsupportedUnits.map(\.jsonValue)),
            "untranslated": .array(untranslated.map(\.jsonValue)),
            "machineTranslated": .array(machineTranslated.map(\.jsonValue)),
            "missingFromBundle": .array(missingFromBundle.map { .string($0) }),
            "metadataProblems": .array(metadataProblems.map { .string($0) }),
            "failures": .number("\(failures)"),
            "advisories": .number("\(advisories)"),
        ])
    }
}

/// Validates a localization catalog before it is imported.
///
/// This is the moment worth checking: an `.xcloc` comes back from a vendor,
/// someone runs `xcodebuild -importLocalizations`, and a `%@` where the code
/// passes an integer is now in the app. Xcode's import warns about untranslated
/// files; it does not compare format specifiers.
public struct XclocCheckCommand {
    private let workspace: Workspace
    private let compareAgainstProject: Bool

    public init(workspace: Workspace, compareAgainstProject: Bool = true) {
        self.workspace = workspace
        self.compareAgainstProject = compareAgainstProject
    }

    public func run(bundlePath: String) throws -> XclocCheckReport {
        let bundle = try LocalizationCatalog.load(path: bundlePath)
        var report = XclocCheckReport(bundle: bundle.displayName, targetLanguage: bundle.targetLanguage)

        // contents.json and the XLIFF must agree about the language, or the
        // translations are about to be filed under the wrong locale.
        for document in bundle.documents {
            for file in document.files {
                guard let declared = file.targetLanguage, let expected = bundle.contents.targetLocale,
                      !declared.isEmpty, !expected.isEmpty, declared != expected else { continue }
                report.metadataProblems.append(
                    "\((document.path as NSString).lastPathComponent) declares target-language \"\(declared)\" "
                    + "but contents.json says \"\(expected)\""
                )
            }
        }

        let language = bundle.targetLanguage
        var pluralCategories: [String: Set<String>] = [:]   // key → categories present
        var keysByTable: [String: Set<String>] = [:]

        for document in bundle.documents {
            let fileName = (document.path as NSString).lastPathComponent
            for file in document.files {
                for unit in file.units {
                    report.unitCount += 1
                    let parsed = TransUnitKey(id: unit.id)
                    keysByTable[file.table, default: []].insert(parsed.key)

                    if case .unsupported(let path) = parsed.configuration {
                        report.unsupportedUnits.append(XclocFinding(
                            unitID: unit.id, file: fileName, line: unit.line,
                            problem: "unrecognised variation \"\(path)\"; this unit cannot be applied"
                        ))
                        continue
                    }

                    guard unit.isTranslated, let target = unit.target else {
                        report.untranslated.append(XclocFinding(
                            unitID: unit.id, file: fileName, line: unit.line,
                            problem: "no translation"
                        ))
                        continue
                    }
                    report.translatedCount += 1

                    if unit.isMachineTranslated {
                        report.machineTranslated.append(XclocFinding(
                            unitID: unit.id, file: fileName, line: unit.line,
                            problem: "machine translation (\(unit.stateQualifier ?? "mt")) — review before shipping"
                        ))
                    }

                    if let problem = FormatSpecifierScanner.mismatch(source: unit.source, translation: target) {
                        report.formatMismatches.append(XclocFinding(
                            unitID: unit.id, file: fileName, line: unit.line,
                            problem: problem
                        ))
                    }

                    if case .plural(let category) = parsed.configuration {
                        pluralCategories[parsed.key, default: []].insert(category)
                    }
                }
            }
        }

        // Plural completeness, per the categories the target language requires.
        if let language {
            let required = PluralRules.categories(for: language).required
            for (key, present) in pluralCategories.sorted(by: { $0.key < $1.key }) {
                let missing = required.filter { !present.contains($0) }
                guard !missing.isEmpty else { continue }
                report.pluralGaps.append(XclocFinding(
                    unitID: key, file: bundle.displayName, line: 0,
                    problem: "\(language) needs \(missing.joined(separator: ", "))"
                ))
            }
        }

        guard compareAgainstProject, !workspace.targets.isEmpty else { return report }

        // Cross-check against the catalogs this project actually ships.
        var projectKeys: [String: Set<String>] = [:]
        for target in workspace.targets {
            for catalog in workspace.catalogs(for: target) {
                guard let table = catalog.kind.tableName else { continue }
                projectKeys[table, default: []].formUnion(catalog.keys)
            }
        }
        guard !projectKeys.isEmpty else { return report }

        for (table, keys) in keysByTable.sorted(by: { $0.key < $1.key }) {
            let known = projectKeys[table] ?? []
            for key in keys.sorted() where !known.contains(key) {
                report.unknownKeys.append(XclocFinding(
                    unitID: key, file: "\(table).strings", line: 0,
                    problem: known.isEmpty
                        ? "no \(table) catalog in this project"
                        : "not a key in the \(table) catalog"
                ))
            }
            for key in (projectKeys[table] ?? []).sorted()
            where !keys.contains(key) && KeyHeuristics.isTranslatable(key) {
                report.missingFromBundle.append(key)
            }
        }
        return report
    }
}

/// Applies a localization catalog to the project's string catalogs.
///
/// This is `xcodebuild -importLocalizations` without a project or a build:
/// useful in CI, and it keeps the catalog's structure rather than rewriting it.
public struct XclocApplyCommand {
    public struct Options {
        public var dryRun: Bool
        public var language: String?
        public var includeMachineTranslations: Bool

        public init(dryRun: Bool = true, language: String? = nil, includeMachineTranslations: Bool = true) {
            self.dryRun = dryRun
            self.language = language
            self.includeMachineTranslations = includeMachineTranslations
        }
    }

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run(bundlePath: String) throws -> [WriteReport] {
        let bundle = try LocalizationCatalog.load(path: bundlePath)
        guard let language = options.language ?? bundle.targetLanguage else {
            throw SmithError.usage("cannot tell which language this bundle is for; pass --lang")
        }

        // Group units by the catalog they belong to, so each catalog is written once.
        var byCatalog: [String: (catalog: Catalog, units: [(TransUnitKey, XLIFFUnit)])] = [:]
        var unresolved: [String] = []

        for document in bundle.documents {
            for file in document.files {
                var destination: Catalog?
                for target in workspace.targets {
                    if let catalog = workspace.catalog(for: file.table, in: target) {
                        destination = catalog
                        break
                    }
                }
                guard let catalog = destination else {
                    unresolved.append(file.table)
                    continue
                }
                var entry = byCatalog[catalog.path] ?? (catalog, [])
                for unit in file.units where unit.isTranslated {
                    if unit.isMachineTranslated && !options.includeMachineTranslations { continue }
                    entry.units.append((TransUnitKey(id: unit.id), unit))
                }
                byCatalog[catalog.path] = entry
            }
        }

        var reports: [WriteReport] = []
        for path in byCatalog.keys.sorted() {
            guard var entry = byCatalog[path] else { continue }
            var report = WriteReport(catalog: entry.catalog.displayPath, language: language)
            report.dryRun = options.dryRun

            for (parsed, unit) in entry.units {
                guard let value = unit.target else { continue }
                let state = XLIFFState.catalogState(state: unit.state, qualifier: unit.stateQualifier)

                // A key the project does not have is not invented: an XLIFF is
                // a translation of a catalog, not a source of new keys.
                guard entry.catalog.contains(parsed.key) else {
                    report.refusals.append(.init(
                        key: parsed.key,
                        reason: "no such key in \(entry.catalog.displayPath); an XLIFF translates a catalog, it does not extend one"
                    ))
                    continue
                }

                switch parsed.configuration {
                case .simple:
                    do {
                        let existed = try entry.catalog.setTranslation(
                            key: parsed.key, language: language, value: value, state: state
                        )
                        report.changes.append(.init(key: parsed.key, action: existed ? .updated : .translated))
                    } catch let error as SmithError {
                        guard case .wouldDiscardStructure(_, _, let structure) = error else { throw error }
                        report.refusals.append(.init(
                            key: parsed.key,
                            reason: "holds \(structure); edit it in Xcode"
                        ))
                    }

                case .plural(let category):
                    do {
                        try entry.catalog.setPluralTranslation(
                            key: parsed.key, language: language, category: category,
                            value: value, state: state
                        )
                        report.changes.append(.init(
                            key: parsed.key, action: .translated, detail: "plural.\(category)"
                        ))
                    } catch let error as SmithError {
                        guard case .wouldDiscardStructure(_, _, let structure) = error else { throw error }
                        report.refusals.append(.init(
                            key: parsed.key,
                            reason: "holds \(structure); edit it in Xcode"
                        ))
                    }

                case .device(let name):
                    entry.catalog.setDeviceTranslation(
                        key: parsed.key, language: language, device: name,
                        value: value, state: state
                    )
                    report.changes.append(.init(key: parsed.key, action: .translated, detail: "device.\(name)"))

                case .substitutionPlural(let name, let category):
                    let applied = entry.catalog.setSubstitutionPluralTranslation(
                        key: parsed.key, language: language, substitution: name,
                        category: category, value: value, state: state
                    )
                    if applied {
                        report.changes.append(.init(
                            key: parsed.key, action: .translated,
                            detail: "substitution \(name).plural.\(category)"
                        ))
                    } else {
                        report.refusals.append(.init(
                            key: parsed.key,
                            reason: "no substitution \"\(name)\" is declared; Xcode must create it first"
                        ))
                    }

                case .unsupported(let path):
                    report.refusals.append(.init(key: parsed.key, reason: "unrecognised variation \"\(path)\""))
                }
            }

            if !options.dryRun, !report.changes.isEmpty {
                try workspace.save(entry.catalog)
            }
            reports.append(report)
        }

        if !unresolved.isEmpty {
            var report = WriteReport(catalog: "(unmatched tables)", language: language)
            report.dryRun = options.dryRun
            report.refusals = Array(Set(unresolved)).sorted().map {
                .init(key: $0, reason: "no catalog for this table in the project")
            }
            reports.append(report)
        }
        return reports
    }
}
