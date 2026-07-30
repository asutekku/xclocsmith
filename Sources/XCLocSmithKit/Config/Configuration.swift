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

    public init(name: String, sources: [String], referenceSources: [String] = [], catalogs: [String]) {
        self.name = name
        self.sources = sources
        self.referenceSources = referenceSources
        self.catalogs = catalogs
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
    public var localizableParams: Set<String> = [
        "title", "titleKey", "label", "labelKey", "header", "footer", "prompt",
        "message", "description", "placeholder", "subtitle", "caption", "hint",
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
    ]
    /// Non-Swift files searched before a key is called orphaned.
    public var referenceExtensions: Set<String> = [
        "plist", "strings", "stringsdict", "storyboard", "xib",
        "intentdefinition", "m", "mm", "h", "json", "yaml", "yml",
    ]
    public var similarityThreshold = 85
    public var scanPreviews = false

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
            skipCalls: skipCalls
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
                    catalogs: catalogs
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
            return .object(entry)
        })
        fields["languages"] = .array(languages.sorted().map { .string($0) })
        fields["excludePaths"] = .array(excludePatterns.map { .string($0) })
        fields["ignoreStrings"] = .array(ignoredStrings.sorted().map { .string($0) })
        fields["ignoreSimilar"] = .array([])
        fields["similarityThreshold"] = .number("\(similarityThreshold)")
        fields["scanPreviews"] = .bool(scanPreviews)
        return JSONWriter.text(.object(fields), style: .plain)
    }
}
