import Foundation

/// An Xcode Localization Catalog — the `.xcloc` bundle produced by
/// `xcodebuild -exportLocalizations` and handed to localizers.
///
/// Apple's layout:
///
/// ```
/// ja.xcloc/
///   contents.json          metadata: development region, locale, tool, version
///   Localized Contents/    the XLIFF for the target language
///   Source Contents/       source files that give localizers context
///   Notes/                 screenshots, movies, notes
/// ```
public struct LocalizationCatalog {
    public let path: String
    public let displayName: String
    public let contents: Contents
    public let documents: [XLIFFDocument]

    public struct Contents: Equatable, Sendable {
        public let developmentRegion: String?
        public let targetLocale: String?
        public let toolName: String?
        public let toolVersion: String?
        public let version: String?
    }

    public static let localizedContentsDirectory = "Localized Contents"
    public static let sourceContentsDirectory = "Source Contents"
    public static let notesDirectory = "Notes"
    public static let contentsFileName = "contents.json"

    public init(path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SmithError.cannotRead(path: path, reason: "not a directory — an .xcloc is a bundle")
        }

        self.path = resolved.path
        self.displayName = resolved.lastPathComponent

        let contentsPath = resolved.appendingPathComponent(Self.contentsFileName)
        if let data = FileManager.default.contents(atPath: contentsPath.path) {
            let document: JSONValue
            do {
                document = try JSONParser.parse(data)
            } catch let error as JSONParseError {
                throw SmithError.invalidPayload(
                    path: "\(displayName)/\(Self.contentsFileName)",
                    reason: error.description
                )
            }
            self.contents = Contents(
                developmentRegion: document["developmentRegion"]?.stringValue,
                targetLocale: document["targetLocale"]?.stringValue,
                toolName: document["toolInfo"]?["toolName"]?.stringValue,
                toolVersion: document["toolInfo"]?["toolBuildNumber"]?.stringValue
                    ?? document["toolInfo"]?["toolVersion"]?.stringValue,
                version: document["version"]?.stringValue
            )
        } else {
            self.contents = Contents(
                developmentRegion: nil, targetLocale: nil,
                toolName: nil, toolVersion: nil, version: nil
            )
        }

        let localized = resolved.appendingPathComponent(Self.localizedContentsDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localized.path)) ?? []
        let xliffPaths = names.filter { $0.hasSuffix(".xliff") }.sorted()
        guard !xliffPaths.isEmpty else {
            throw SmithError.invalidPayload(
                path: displayName,
                reason: "no .xliff found in \"\(Self.localizedContentsDirectory)\""
            )
        }
        self.documents = try xliffPaths.map {
            try XLIFFParser.parse(contentsOf: localized.appendingPathComponent($0).path)
        }
    }

    /// The language this catalog is for: `contents.json` first, then whatever
    /// the XLIFF files declare, then the bundle's own name.
    public var targetLanguage: String? {
        if let locale = contents.targetLocale, !locale.isEmpty { return locale }
        if let declared = documents.compactMap({ $0.files.first?.targetLanguage }).first { return declared }
        let name = (displayName as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }

    /// Accepts either an `.xcloc` bundle or a bare `.xliff` file, since
    /// localizers routinely return just the XLIFF.
    public static func load(path: String) throws -> LocalizationCatalog {
        if path.hasSuffix(".xliff") {
            let document = try XLIFFParser.parse(contentsOf: path)
            return LocalizationCatalog(
                path: path,
                displayName: (path as NSString).lastPathComponent,
                contents: Contents(
                    developmentRegion: document.files.first?.sourceLanguage,
                    targetLocale: document.files.first?.targetLanguage,
                    toolName: nil, toolVersion: nil, version: nil
                ),
                documents: [document]
            )
        }
        return try LocalizationCatalog(path: path)
    }

    private init(path: String, displayName: String, contents: Contents, documents: [XLIFFDocument]) {
        self.path = path
        self.displayName = displayName
        self.contents = contents
        self.documents = documents
    }
}

/// A `trans-unit` id decomposed into the catalog key and the variation it addresses.
///
/// Xcode encodes variations by appending a separator and a dot-separated
/// configuration path, so one catalog key becomes several units:
/// `"%lld items|==|plural.one"`.
public struct TransUnitKey: Equatable, Sendable {
    public static let separator = "|==|"

    public enum Configuration: Equatable, Sendable {
        case simple
        case plural(category: String)
        case device(name: String)
        case substitutionPlural(name: String, category: String)
        /// A shape this tool will not guess at. Reported and skipped rather
        /// than written to the wrong place.
        case unsupported(String)
    }

    public let key: String
    public let configuration: Configuration

    public init(id: String) {
        guard let range = id.range(of: Self.separator) else {
            self.key = id
            self.configuration = .simple
            return
        }
        self.key = String(id[id.startIndex..<range.lowerBound])
        let path = String(id[range.upperBound...])
        let segments = path.split(separator: ".").map(String.init)

        switch segments.count {
        case 2 where segments[0] == "plural" && PluralRules.allCategories.contains(segments[1]):
            self.configuration = .plural(category: segments[1])
        case 2 where segments[0] == "device":
            self.configuration = .device(name: segments[1])
        case 3 where segments[1] == "plural" && PluralRules.allCategories.contains(segments[2]):
            self.configuration = .substitutionPlural(name: segments[0], category: segments[2])
        case 4 where segments[0] == "substitutions" && segments[2] == "plural"
            && PluralRules.allCategories.contains(segments[3]):
            self.configuration = .substitutionPlural(name: segments[1], category: segments[3])
        default:
            self.configuration = .unsupported(path)
        }
    }
}
