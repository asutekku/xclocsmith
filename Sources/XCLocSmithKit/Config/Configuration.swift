import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One build product: the sources that compile into it and the catalogs it ships.
///
/// A target can own several catalogs — one per string table — because
/// `Text("Key", tableName: "Errors")` reads `Errors.xcstrings`. Resolving the
/// table at the call site is the only way to tell a missing key from a key that
/// simply lives in another table.
public struct Target: Equatable, Sendable {
    public var name: String
    /// Directories whose code compiles into this target.
    public var sources: [String]
    /// Extra directories scanned only to decide whether a key is still
    /// referenced. Shared packages go here when it is not certain which targets
    /// compile them: it prevents false orphans without demanding that every
    /// catalog carry every shared string.
    public var referenceSources: [String]
    /// Catalog paths, keyed by table at resolution time.
    public var catalogs: [String]
    /// True when this target was guessed from the directory layout rather than
    /// declared. Without the build settings there is no way to know which
    /// target compiles a shared file, so a key found in another target's
    /// catalog for the same table is accepted rather than reported missing.
    /// A hand-written config means the author does know, and is taken at its
    /// word.
    public var inferred: Bool

    public init(
        name: String,
        sources: [String],
        referenceSources: [String] = [],
        catalogs: [String],
        inferred: Bool = false
    ) {
        self.name = name
        self.sources = sources
        self.referenceSources = referenceSources
        self.catalogs = catalogs
        self.inferred = inferred
    }
}

public struct Configuration {
    public static let fileName = ".xclocsmith.json"

    /// Directory that all relative paths resolve against.
    public var root: String
    public var configPath: String?
    public var targets: [Target] = []
    public var languages: [String] = []

    public var excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage",
        "node_modules", "build", ".claude", ".cache", ".venv", "vendor",
    ]
    public var excludePatterns: [String] = []
    public var ignoredStrings: Set<String> = []
    public var ignoredSimilarPairs: Set<String> = []

    public var localizableCalls: Set<String> = []
    public var localizableModifiers: Set<String> = []
    /// Members that localize the literal they are accessed on. The
    /// `"key".localized` extension is near-universal in projects predating
    /// String Catalogs, and it is the entire localization API in some.
    public var localizedAccessors: Set<String> = [
        "localized", "localizedString", "localizedValue", "loc", "l10n",
    ]
    /// Parameter names guessed to be display text when nothing in the project
    /// says otherwise. This is the weakest rule the classifier has — it fires
    /// on a name alone — so it holds only names that no common non-UI API uses.
    ///
    /// Three names left this list after the nine-project sample, each because
    /// no Apple API takes display text under that label:
    ///
    /// - `description:` — `XCTestExpectation`, `NSError` and
    ///   `CustomStringConvertible` use it; no localization API does.
    /// - `header:` and `footer:` — SwiftUI's are `@ViewBuilder`, never a
    ///   string, so a literal there belongs to somebody else's type. Whisky's
    ///   were a `TextTableColumn(header:)` in a command-line target.
    ///
    /// A project that does display one is still caught by the evidence-based
    /// rule, which reads the declaring type instead of guessing from the name.
    public var localizableParams: Set<String> = [
        "title", "titleKey", "label", "labelKey", "prompt",
        "message", "placeholder", "subtitle", "caption", "hint",
    ]
    public var skipParams: Set<String> = [
        "systemImage", "systemName", "imageName", "image", "icon", "iconName",
        "symbol", "named", "forKey", "key", "keyPath", "identifier", "id", "tag",
        "reuseIdentifier", "storageKey", "defaultsKey", "coder", "ofType",
        "forResource", "url", "urlString", "font", "fontName", "color", "hex",
        "path", "contentsOfFile", "scheme", "host", "mimeType", "encoding",
        "separator", "terminator", "pattern",
    ]
    public var skipCalls: Set<String> = [
        "Image", "UIImage", "NSImage", "URL", "URLComponents", "UUID", "Font",
        "Color", "AppStorage", "SceneStorage", "UserDefaults", "Notification",
        "NSPredicate", "Predicate", "Bundle", "NumberFormatter", "DateFormatter",
        "Locale", "Data", "print", "debugPrint", "assert", "assertionFailure",
        "precondition", "preconditionFailure", "fatalError", "Logger", "os_log",
        "NSLog", "Set", "Array", "Dictionary", "Int", "Double", "Decimal", "Date",
        "XCTAssertEqual", "XCTAssertTrue", "XCTAssertFalse", "XCTFail",
        // Take a `label:`, `message:` or `title:` that is an identifier, a
        // compiler directive or a log line. Each was a real false positive in
        // the sample: `DispatchQueue(label: "net.hearthsim.hstracker.readers")`,
        // `@available(*, deprecated, message: "…")`, `expectation(description:)`.
        "DispatchQueue", "OperationQueue", "Thread", "available",
        "expectation", "XCTestExpectation", "XCTSkip", "XCTUnwrap",
        "os_signpost", "OSSignposter", "OSLog", "Signposter",
        "NSSortDescriptor", "SortDescriptor", "NSError", "CodingUserInfoKey",
        "NSExpression", "NSRegularExpression", "Scanner",
    ]
    /// Non-Swift files searched before a key is called orphaned.
    public var referenceExtensions: Set<String> = [
        "plist", "strings", "stringsdict", "storyboard", "xib",
        "intentdefinition", "m", "mm", "h", "json", "yaml", "yml",
    ]
    public var similarityThreshold = 85
    public var scanPreviews = false
    /// Terms whose translation the project has fixed. Empty by default: a
    /// glossary is a set of decisions, and this tool has no way to guess them.
    public var glossary = Glossary()

    public init(root: String, configPath: String? = nil) {
        self.root = root
        self.configPath = configPath
    }

    public var classifierOptions: ClassifierOptions {
        ClassifierOptions(
            localizableParams: localizableParams,
            localizableCalls: localizableCalls,
            localizableModifiers: localizableModifiers,
            skipParams: skipParams,
            skipCalls: skipCalls,
            localizedAccessors: localizedAccessors
        )
    }

    // MARK: - Paths

    public func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: root).appendingPathComponent(path).standardized.path
    }

    public func display(_ absolutePath: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return absolutePath.hasPrefix(prefix) ? String(absolutePath.dropFirst(prefix.count)) : absolutePath
    }

    public func isExcluded(_ absolutePath: String) -> Bool {
        let relative = display(absolutePath)
        for component in relative.split(separator: "/") where excludedDirectories.contains(String(component)) {
            return true
        }
        return excludePatterns.contains { pattern in
            pattern.withCString { p in relative.withCString { s in fnmatch(p, s, 0) == 0 } }
        }
    }

    // MARK: - Loading

    public static func findConfigFile(startingAt directory: String) -> String? {
        var current = URL(fileURLWithPath: directory).standardized
        while true {
            let candidate = current.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    public static func load(explicitPath: String?, useConfigFile: Bool, workingDirectory: String) throws -> Configuration {
        let path = explicitPath ?? (useConfigFile ? findConfigFile(startingAt: workingDirectory) : nil)

        guard let path else {
            var configuration = Configuration(root: workingDirectory)
            configuration.targets = try ProjectDiscovery.discoverTargets(
                root: workingDirectory,
                excluded: configuration.excludedDirectories
            )
            return configuration
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw SmithError.cannotRead(path: path, reason: "unreadable")
        }
        let document: JSONValue
        do {
            document = try JSONParser.parse(data)
        } catch let error as JSONParseError {
            throw SmithError.invalidConfiguration(path: path, reason: error.description)
        }
        guard let fields = document.objectValue else {
            throw SmithError.invalidConfiguration(path: path, reason: "top level must be a JSON object")
        }

        let root = URL(fileURLWithPath: path).deletingLastPathComponent().standardized.path
        var configuration = Configuration(root: root, configPath: path)

        if let values = fields["exclude"]?.stringList { configuration.excludedDirectories = Set(values) }
        if let values = fields["excludeAlso"]?.stringList { configuration.excludedDirectories.formUnion(values) }
        if let values = fields["excludePaths"]?.stringList { configuration.excludePatterns = values }
        if let values = fields["languages"]?.stringList { configuration.languages = values }
        if let values = fields["ignoreStrings"]?.stringList { configuration.ignoredStrings = Set(values) }
        if let pairs = fields["ignoreSimilar"]?.arrayValue {
            for pair in pairs {
                guard let items = pair.stringList, items.count == 2 else { continue }
                configuration.ignoredSimilarPairs.insert(SimilarKeys.canonicalPair(items[0], items[1]))
            }
        }
        if let values = fields["localizableCalls"]?.stringList { configuration.localizableCalls.formUnion(values) }
        if let values = fields["localizableModifiers"]?.stringList { configuration.localizableModifiers.formUnion(values) }
        if let values = fields["localizableParams"]?.stringList { configuration.localizableParams.formUnion(values) }
        if let values = fields["skipParams"]?.stringList { configuration.skipParams.formUnion(values) }
        if let values = fields["skipCalls"]?.stringList { configuration.skipCalls.formUnion(values) }
        if let values = fields["referenceExtensions"]?.stringList { configuration.referenceExtensions = Set(values) }
        if let threshold = fields["similarityThreshold"]?.intValue {
            guard (50...99).contains(threshold) else {
                throw SmithError.invalidConfiguration(path: path, reason: "similarityThreshold must be between 50 and 99")
            }
            configuration.similarityThreshold = threshold
        }
        if let flag = fields["scanPreviews"]?.boolValue { configuration.scanPreviews = flag }

        if let entry = fields["glossary"] {
            guard let terms = entry.objectValue else {
                throw SmithError.invalidConfiguration(
                    path: path,
                    reason: "\"glossary\" must be an object of term → { language: rendering }"
                )
            }
            for (term, value) in terms {
                // Skipping a malformed entry would leave the check silently
                // doing nothing, which is the one outcome nobody would notice.
                guard let renderings = value.objectValue, !renderings.isEmpty else {
                    throw SmithError.invalidConfiguration(
                        path: path,
                        reason: "glossary term \"\(term)\" needs at least one language, or \"*\" for all of them"
                    )
                }
                var byLanguage: [String: String] = [:]
                for (language, rendering) in renderings {
                    guard let text = rendering.stringValue else {
                        throw SmithError.invalidConfiguration(
                            path: path,
                            reason: "glossary term \"\(term)\" has a non-string rendering for \(language)"
                        )
                    }
                    byLanguage[language] = text
                }
                configuration.glossary.terms[term] = byLanguage
            }
        }

        if let targets = fields["targets"]?.arrayValue {
            configuration.targets = try targets.map { entry in
                guard let target = entry.objectValue else {
                    throw SmithError.invalidConfiguration(path: path, reason: "each target must be an object")
                }
                guard let catalogs = target["catalogs"]?.stringList ?? target["catalog"]?.stringList, !catalogs.isEmpty else {
                    throw SmithError.invalidConfiguration(path: path, reason: "each target needs \"catalogs\"")
                }
                let name = target["name"]?.stringValue
                    ?? URL(fileURLWithPath: catalogs[0]).deletingLastPathComponent().lastPathComponent
                return Target(
                    name: name,
                    sources: target["sources"]?.stringList ?? [],
                    referenceSources: target["referenceSources"]?.stringList ?? [],
                    catalogs: catalogs,
                    inferred: target["inferred"]?.boolValue ?? false
                )
            }
        } else if let catalogs = fields["catalogs"]?.stringList {
            configuration.targets = [Target(
                name: "default",
                sources: fields["sources"]?.stringList ?? ["."],
                referenceSources: fields["referenceSources"]?.stringList ?? [],
                catalogs: catalogs
            )]
        }

        if configuration.targets.isEmpty {
            configuration.targets = try ProjectDiscovery.discoverTargets(
                root: root,
                excluded: configuration.excludedDirectories
            )
        }
        return configuration
    }

    public func serialized() -> String {
        var fields: [String: JSONValue] = [:]
        fields["targets"] = .array(targets.map { target in
            var entry: [String: JSONValue] = [
                "name": .string(target.name),
                "sources": .array(target.sources.map { .string($0) }),
                "catalogs": .array(target.catalogs.map { .string($0) }),
            ]
            if !target.referenceSources.isEmpty {
                entry["referenceSources"] = .array(target.referenceSources.map { .string($0) })
            }
            // Written so the guess survives the round-trip. Delete it once the
            // sources really are this target's, and a key in another target's
            // catalog stops counting.
            if target.inferred { entry["inferred"] = .bool(true) }
            return .object(entry)
        })
        fields["languages"] = .array(languages.sorted().map { .string($0) })
        fields["excludePaths"] = .array(excludePatterns.map { .string($0) })
        fields["ignoreStrings"] = .array(ignoredStrings.sorted().map { .string($0) })
        fields["ignoreSimilar"] = .array([])
        // Written empty so it is discoverable: `"Onsen": {"ja": "温泉"}`, or
        // `{"*": "Furolog"}` for a name that must survive every language.
        fields["glossary"] = .object(glossary.terms.mapValues { renderings in
            .object(renderings.mapValues { .string($0) })
        })
        fields["similarityThreshold"] = .number("\(similarityThreshold)")
        fields["scanPreviews"] = .bool(scanPreviews)
        return JSONWriter.text(.object(fields), style: .plain)
    }
}
