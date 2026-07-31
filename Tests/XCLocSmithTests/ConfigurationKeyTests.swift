import XCTest
@testable import XCLocSmithKit

/// Every key `.xclocsmith.json` accepts, asserted to actually change something.
///
/// `localizedAccessors` was documented in two places, had a default list, and
/// was honoured by the classifier — and the parser never read it, so a project
/// that declared its own `.t` accessor was quietly told nothing localizes it.
/// Nothing failed: the key was simply ignored, which is the one kind of
/// configuration bug a user cannot debug from the outside.
///
/// The list below is the specification. A new key belongs here first.
final class ConfigurationKeyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A config without `targets` falls through to discovery, which needs a
        // catalog to find.
        try #"{"sourceLanguage":"en","strings":{},"version":"1.0"}"#
            .write(to: root.appendingPathComponent("Localizable.xcstrings"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func load(_ json: String) throws -> Configuration {
        let path = root.appendingPathComponent(Configuration.fileName)
        try json.write(to: path, atomically: true, encoding: .utf8)
        return try Configuration.load(
            explicitPath: path.path,
            useConfigFile: true,
            workingDirectory: root.path
        )
    }

    /// Every documented key, in one file, each asserted to have landed.
    func testEveryDocumentedKeyTakesEffect() throws {
        let configuration = try load("""
        {
          "targets": [
            {
              "name": "App",
              "sources": ["App"],
              "catalogs": ["App/Localizable.xcstrings"],
              "referenceSources": ["Packages/Shared"],
              "inferred": true
            }
          ],
          "languages": ["ja", "de"],
          "exclude": ["Vendor"],
          "excludeAlso": ["Snapshots"],
          "excludePaths": ["**/Generated/*.swift"],
          "ignoreStrings": ["debug only"],
          "ignoreSimilar": [["Max Temperature", "Min Temperature"]],
          "localizableCalls": ["Banner"],
          "localizableModifiers": ["captionText"],
          "localizableParams": ["heading"],
          "localizedAccessors": ["t"],
          "skipCalls": ["Analytics"],
          "skipParams": ["identifier"],
          "referenceExtensions": ["swift", "kt"],
          "similarityThreshold": 70,
          "scanPreviews": true,
          "glossary": { "Onsen": { "ja": "温泉", "*": "Onsen" } }
        }
        """)

        XCTAssertEqual(configuration.targets.count, 1)
        XCTAssertEqual(configuration.targets.first?.name, "App")
        XCTAssertEqual(configuration.targets.first?.sources, ["App"])
        XCTAssertEqual(configuration.targets.first?.catalogs, ["App/Localizable.xcstrings"])
        XCTAssertEqual(configuration.targets.first?.referenceSources, ["Packages/Shared"])
        XCTAssertEqual(configuration.targets.first?.inferred, true)

        XCTAssertEqual(configuration.languages, ["ja", "de"])
        XCTAssertTrue(configuration.excludedDirectories.contains("Vendor"))
        XCTAssertTrue(configuration.excludedDirectories.contains("Snapshots"))
        XCTAssertEqual(configuration.excludePatterns, ["**/Generated/*.swift"])
        XCTAssertTrue(configuration.ignoredStrings.contains("debug only"))
        XCTAssertEqual(configuration.ignoredSimilarPairs.count, 1)

        XCTAssertTrue(configuration.localizableCalls.contains("Banner"))
        XCTAssertTrue(configuration.localizableModifiers.contains("captionText"))
        XCTAssertTrue(configuration.localizableParams.contains("heading"))
        XCTAssertTrue(configuration.localizedAccessors.contains("t"))
        XCTAssertTrue(configuration.skipCalls.contains("Analytics"))
        XCTAssertTrue(configuration.skipParams.contains("identifier"))
        XCTAssertEqual(configuration.referenceExtensions, ["swift", "kt"])
        XCTAssertEqual(configuration.similarityThreshold, 70)
        XCTAssertTrue(configuration.scanPreviews)
        XCTAssertEqual(configuration.glossary.terms["Onsen"]?["ja"], "温泉")
    }

    /// The regression itself, end to end: a project's own accessor has to reach
    /// the classifier, or declaring one does nothing at all.
    func testADeclaredAccessorMakesItsLiteralUserVisible() throws {
        let configuration = try load("""
        { "localizedAccessors": ["t"] }
        """)
        let file = AnalyzedSource(
            path: "/tmp/T.swift",
            displayPath: "T.swift",
            text: #"let title = "Take a bath".t"#
        )
        let found = SourceAnalyzer.analyze(
            file: file,
            discovered: LocalizableDiscovery.discover(in: [file]),
            options: configuration.classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )

        XCTAssertEqual(found.strings.map(\.value), ["Take a bath"])
    }

    /// The built-in accessors survive a config that names its own.
    func testDeclaringAnAccessorExtendsTheDefaultsRatherThanReplacingThem() throws {
        let configuration = try load("""
        { "localizedAccessors": ["t"] }
        """)
        XCTAssertTrue(configuration.localizedAccessors.contains("t"))
        XCTAssertTrue(configuration.localizedAccessors.contains("localized"))
    }

    /// `exclude` replaces the built-in directory list, `excludeAlso` adds to it.
    /// The two differ, and a project that wants the defaults plus one more will
    /// reach for the wrong one if they quietly behave the same.
    func testExcludeReplacesAndExcludeAlsoExtends() throws {
        let replaced = try load(#"{ "exclude": ["Vendor"] }"#)
        XCTAssertEqual(replaced.excludedDirectories, ["Vendor"])

        let extended = try load(#"{ "excludeAlso": ["Vendor"] }"#)
        XCTAssertTrue(extended.excludedDirectories.contains("Vendor"))
        XCTAssertGreaterThan(extended.excludedDirectories.count, 1)
    }

    /// Documented as 50–99, and a value outside it is a mistake worth naming
    /// rather than clamping silently.
    func testAnOutOfRangeThresholdIsRejected() {
        XCTAssertThrowsError(try load(#"{ "similarityThreshold": 5 }"#))
        XCTAssertThrowsError(try load(#"{ "similarityThreshold": 100 }"#))
    }
}
