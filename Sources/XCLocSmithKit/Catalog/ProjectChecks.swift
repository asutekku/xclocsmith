import Foundation

/// Defects that live between files rather than inside one.
///
/// These are the checks nothing else can run. A translation-management system
/// sees a catalog and not the project around it; Xcode compiles the project and
/// never compares one catalog against another. Both of the findings here are
/// invisible from either side alone, and both ship as a user in some language
/// reading English.
public struct ProjectFinding: Equatable, Sendable {
    public enum Rule: String, Sendable, CaseIterable {
        /// An `Info.plist` key users read, with no entry in `InfoPlist.xcstrings`.
        case infoPlistNotLocalized = "info-plist-not-localized"
        /// The bundle's development region is not the catalog's source language.
        case developmentRegionMismatch = "development-region-mismatch"
        /// One catalog ships fewer languages than its neighbours.
        case languageCoverageGap = "language-coverage-gap"

        public var summary: String {
            switch self {
            case .infoPlistNotLocalized:
                return "an Info.plist string users read, with no catalog entry"
            case .developmentRegionMismatch:
                return "the bundle's development region is not the catalog's source language"
            case .languageCoverageGap:
                return "a catalog shipping fewer languages than its neighbours"
            }
        }
    }

    public let rule: Rule
    public let detail: String
    /// The file the finding is about, so an annotation has somewhere to land.
    public let file: String?
    public let isFailure: Bool

    public init(rule: Rule, detail: String, file: String?, isFailure: Bool) {
        self.rule = rule
        self.detail = detail
        self.file = file
        self.isFailure = isFailure
    }
}

public enum ProjectChecks {

    /// `Info.plist` keys whose values a user reads, and which therefore have to
    /// be translated like any other string.
    ///
    /// Permission prompts are the ones that matter: a French user being asked
    /// for camera access in English is both a bad experience and something App
    /// Review notices. The display name and the copyright line are here for the
    /// same reason.
    /// Deliberately short. `CFBundleName` is `$(PRODUCT_NAME)` in almost every
    /// project and `NSHumanReadableCopyright` is a legal boilerplate line that
    /// hardly anyone translates; both fired on five of the six sample projects
    /// and said nothing. Permission prompts and the display name are the ones a
    /// user reads and App Review looks at.
    static func isUserFacingPlistKey(_ key: String) -> Bool {
        key.hasSuffix("UsageDescription") || key == "CFBundleDisplayName"
    }

    /// `$(PRODUCT_NAME)` and `${EXECUTABLE_NAME}` are build settings, not text.
    private static func isBuildSettingReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("$(") || trimmed.hasPrefix("${")
    }

    /// Info.plist strings that reach no `InfoPlist.xcstrings`.
    ///
    /// Both places a modern project can declare them are read: an actual
    /// `Info.plist` file, and the `INFOPLIST_KEY_…` build settings Xcode has
    /// generated the file from since Xcode 13, which is why a project with no
    /// `Info.plist` at all is not evidence of anything.
    /// Asked once for the whole project rather than once per target.
    ///
    /// Without build settings a target is a guess, and guessed targets share
    /// source directories — so per target, DuckDuckGo reported the same nine
    /// permission strings ten times over. The question "is this string
    /// localized anywhere in this project" has one answer.
    public static func infoPlistCoverage(
        targets: [Target],
        catalogs: [Catalog],
        configuration: Configuration
    ) -> [ProjectFinding] {
        var declared = Set<String>()
        for target in targets {
            declared.formUnion(declaredPlistKeys(target: target, configuration: configuration))
        }
        guard !declared.isEmpty else { return [] }

        // Matched on the kind, not on `tableName` — that is deliberately nil
        // for InfoPlist because source code never names the table, so filtering
        // on it silently matched nothing and told every project it had no
        // InfoPlist.xcstrings, including the ones that do.
        let plistCatalogs = catalogs.filter {
            if case .infoPlist = $0.kind { return true }
            return false
        }
        guard !plistCatalogs.isEmpty else {
            let named = declared.sorted().prefix(4).joined(separator: ", ")
            let rest = declared.count > 4 ? " and \(declared.count - 4) more" : ""
            return [ProjectFinding(
                rule: .infoPlistNotLocalized,
                detail: "\(declared.count) user-visible Info.plist string(s) — \(named)\(rest) — "
                    + "and no InfoPlist.xcstrings anywhere, so every language sees the English",
                file: nil,
                isFailure: false
            )]
        }

        var present = Set<String>()
        for catalog in plistCatalogs { present.formUnion(catalog.keys) }
        let missing = declared.subtracting(present).sorted()
        guard !missing.isEmpty else { return [] }
        return missing.map { key in
            ProjectFinding(
                rule: .infoPlistNotLocalized,
                detail: "\"\(key)\" is in the Info.plist but in no InfoPlist.xcstrings, "
                    + "so it is shown in the development language everywhere",
                file: plistCatalogs[0].displayPath,
                isFailure: false
            )
        }
    }

    /// Every user-facing key the target declares, from either source.
    private static func declaredPlistKeys(
        target: Target,
        configuration: Configuration
    ) -> Set<String> {
        var keys = Set<String>()
        for directory in target.sources {
            let root = configuration.absolute(directory)
            for path in FileCollector.files(
                in: [directory],
                configuration: configuration,
                extensions: ["plist"]
            ) where URL(fileURLWithPath: path).lastPathComponent == "Info.plist" {
                _ = root
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                guard let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any] else { continue }
                for key in plist.keys where isUserFacingPlistKey(key) {
                    // An empty value is a placeholder Xcode wrote, not a string,
                    // and a build-setting reference is resolved at build time.
                    guard let text = plist[key] as? String else { continue }
                    if text.isEmpty || isBuildSettingReference(text) { continue }
                    keys.insert(key)
                }
            }
        }
        keys.formUnion(buildSettingPlistKeys(configuration: configuration))
        return keys
    }

    /// `INFOPLIST_KEY_NSCameraUsageDescription = "…"` in the project file.
    ///
    /// Read as text rather than parsed: the project format is not documented,
    /// and the question here is only which keys are named, which the setting
    /// prefix answers on its own.
    private static func buildSettingPlistKeys(configuration: Configuration) -> Set<String> {
        var keys = Set<String>()
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(atPath: configuration.root) else {
            return keys
        }
        for entry in contents where entry.hasSuffix(".xcodeproj") {
            let path = URL(fileURLWithPath: configuration.root)
                .appendingPathComponent(entry)
                .appendingPathComponent("project.pbxproj").path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let range = line.range(of: "INFOPLIST_KEY_") else { continue }
                let rest = line[range.upperBound...]
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                // A localized variant is written INFOPLIST_KEY_X[en] — the
                // bracket is not part of the key.
                guard !name.isEmpty, isUserFacingPlistKey(name) else { continue }
                keys.insert(name)
            }
        }
        return keys
    }

    /// The bundle's development region against the catalog's source language.
    ///
    /// When they disagree, the language iOS falls back to is not the language
    /// the catalog considers authoritative, so a user matching neither gets
    /// strings from a language nobody chose.
    public static func developmentRegion(
        catalogs: [Catalog],
        configuration: Configuration
    ) -> [ProjectFinding] {
        guard let region = declaredDevelopmentRegion(configuration: configuration) else { return [] }
        let normalized = PluralRules.baseLanguage(region)
        // `$(DEVELOPMENT_LANGUAGE)` and the old spelled-out forms carry no
        // information worth acting on.
        guard !region.hasPrefix("$"), normalized.count == 2 || normalized.count == 3 else {
            return []
        }
        var findings: [ProjectFinding] = []
        for catalog in catalogs where PluralRules.baseLanguage(catalog.sourceLanguage) != normalized {
            findings.append(ProjectFinding(
                rule: .developmentRegionMismatch,
                detail: "the bundle's development region is \(region) but "
                    + "\(catalog.displayPath) has sourceLanguage \(catalog.sourceLanguage)",
                file: catalog.displayPath,
                isFailure: false
            ))
        }
        return findings
    }

    private static func declaredDevelopmentRegion(configuration: Configuration) -> String? {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(atPath: configuration.root) else {
            return nil
        }
        for entry in contents where entry.hasSuffix(".xcodeproj") {
            let path = URL(fileURLWithPath: configuration.root)
                .appendingPathComponent(entry)
                .appendingPathComponent("project.pbxproj").path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("developmentRegion") else { continue }
                guard let equals = line.firstIndex(of: "=") else { continue }
                let value = line[line.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";\""))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Catalogs shipping fewer languages than the project's other catalogs.
    ///
    /// This is the one that surprises people. iOS resolves a language per
    /// bundle, not per app: an `Errors.xcstrings` with twelve languages beside a
    /// `Localizable.xcstrings` with twenty means users in the other eight get
    /// their interface translated and their error messages in English. Nothing
    /// in Xcode compares two catalogs, and each one looks complete on its own.
    public static func languageCoverage(_ catalogs: [Catalog]) -> [ProjectFinding] {
        // A catalog nobody has started is a different problem, already reported
        // as missing translations, and including it here would drag the
        // expected set down to nothing.
        let started = catalogs.filter { $0.languages.count > 1 }
        guard started.count > 1 else { return [] }

        var counts: [String: Int] = [:]
        for catalog in started {
            for language in catalog.languages where language != catalog.sourceLanguage {
                counts[language, default: 0] += 1
            }
        }
        // A language the majority of catalogs carry is one the project ships.
        // One catalog having a language the others do not is that catalog's
        // business; most of them having it and one not is a gap.
        let shipped = Set(counts.filter { $0.value * 2 > started.count }.keys)
        guard !shipped.isEmpty else { return [] }

        var findings: [ProjectFinding] = []
        for catalog in started {
            let present = Set(catalog.languages)
            let absent = shipped.subtracting(present).sorted()
            guard !absent.isEmpty else { continue }
            findings.append(ProjectFinding(
                rule: .languageCoverageGap,
                detail: "\(catalog.displayPath) has no \(absent.joined(separator: ", ")), "
                    + "which \(absent.count == 1 ? "is" : "are") in the project's other catalogs — "
                    + "iOS picks a language per bundle, so those users read this table in "
                    + catalog.sourceLanguage,
                file: catalog.displayPath,
                isFailure: false
            ))
        }
        return findings
    }
}
