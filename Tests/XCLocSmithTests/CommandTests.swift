import XCTest
@testable import XCLocSmithKit

/// End-to-end tests over real directories. These pin the invariants whose
/// violation destroys someone's work: `prune` must never remove a key that
/// source still references, and a report's failure count must equal the
/// findings it actually enumerates.
final class CommandTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture building

    @discardableResult
    private func writeSource(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func writeCatalog(
        _ name: String,
        keys: [String: [String: String]],
        sourceLanguage: String = "en"
    ) throws -> URL {
        var strings: [String: JSONValue] = [:]
        for (key, translations) in keys {
            if translations.isEmpty {
                strings[key] = .object([:])
                continue
            }
            var localizations: [String: JSONValue] = [:]
            for (language, value) in translations {
                localizations[language] = .object([
                    "stringUnit": .object(["state": .string("translated"), "value": .string(value)]),
                ])
            }
            strings[key] = .object(["localizations": .object(localizations)])
        }
        let document = JSONValue.object([
            "sourceLanguage": .string(sourceLanguage),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONWriter.text(document).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func configuration(targets: [Target], languages: [String] = ["ja"]) -> Configuration {
        var configuration = Configuration(root: root.path)
        configuration.targets = targets
        configuration.languages = languages
        return configuration
    }

    // MARK: - prune

    /// The invariant that matters most: a key any source file mentions is never
    /// a prune candidate — including keys written with escapes or in multi-line
    /// literals, which a regex-based scanner misses.
    func testPruneNeverRemovesReferencedKeys() throws {
        try writeSource("App/View.swift", """
            import SwiftUI
            struct V: View {
                var body: some View {
                    Text("Plain key")
                    Text("Escaped \\"quotes\\" and \\n newline")
                    Text(\"""
                        Multi line body
                        \""")
                    Text(flag ? "Ternary" : "Other")
                }
            }
            """)
        try writeCatalog("App/Localizable.xcstrings", keys: [
            "Plain key": [:],
            "Escaped \"quotes\" and \n newline": [:],
            "Multi line body": [:],
            "Ternary": [:],
            "Other": [:],
            "Genuinely unused": [:],
        ])

        let target = Target(name: "App", sources: ["App"], catalogs: ["App/Localizable.xcstrings"])
        var command = PruneCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(dryRun: true)
        )
        let reports = try command.run()
        let removed = reports.flatMap(\.changes).map(\.key)
        XCTAssertEqual(removed, ["Genuinely unused"])
    }

    /// Half-pruning and then reporting a refusal is worse than either outcome,
    /// so nothing is written when any catalog trips the guard.
    func testPruneIsAllOrNothingAcrossCatalogs() throws {
        try writeSource("A/View.swift", #"import SwiftUI\nlet a = Text("Kept A")"#)
        try writeSource("B/View.swift", #"import SwiftUI\nlet b = Text("Kept B")"#)
        try writeCatalog("A/Localizable.xcstrings", keys: ["Kept A": [:], "Dead A": [:]])
        // Almost everything in B is unreferenced, which trips the ratio guard.
        var wholesale: [String: [String: String]] = ["Kept B": [:]]
        for index in 0..<20 { wholesale["Dead B \(index)"] = [:] }
        try writeCatalog("B/Localizable.xcstrings", keys: wholesale)

        let targets = [
            Target(name: "A", sources: ["A"], catalogs: ["A/Localizable.xcstrings"]),
            Target(name: "B", sources: ["B"], catalogs: ["B/Localizable.xcstrings"]),
        ]
        var command = PruneCommand(
            workspace: Workspace(configuration: configuration(targets: targets)),
            options: .init(dryRun: false)
        )
        let reports = try command.run()
        XCTAssertTrue(reports.contains { !$0.refusals.isEmpty })

        // Catalog A must be untouched despite being individually safe.
        let catalogA = try Catalog(path: root.appendingPathComponent("A/Localizable.xcstrings").path)
        XCTAssertNotNil(catalogA.strings["Dead A"])
    }

    /// Info.plist keys never appear in source; offering to delete them would
    /// remove an app's permission strings.
    func testPruneIgnoresInfoPlistCatalogs() throws {
        try writeSource("App/View.swift", #"import SwiftUI\nlet a = Text("Used")"#)
        try writeCatalog("App/Localizable.xcstrings", keys: ["Used": [:]])
        try writeCatalog("App/InfoPlist.xcstrings", keys: ["NSCameraUsageDescription": [:]])

        let target = Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings", "App/InfoPlist.xcstrings"]
        )
        var command = PruneCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(dryRun: true)
        )
        let reports = try command.run()
        XCTAssertTrue(reports.flatMap(\.changes).isEmpty)
    }

    // MARK: - scan

    /// A key that lives in another table does not satisfy a lookup in
    /// Localizable, and a key that does live in the requested table is fine.
    func testScanResolvesTables() throws {
        try writeSource("App/View.swift", """
            import SwiftUI
            let a = Text("In errors", tableName: "Errors")
            let b = Text("Wrong table", tableName: "Errors")
            """)
        try writeCatalog("App/Localizable.xcstrings", keys: ["Wrong table": ["ja": "x"]])
        try writeCatalog("App/Errors.xcstrings", keys: ["In errors": ["ja": "x"]])

        let target = Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings", "App/Errors.xcstrings"]
        )
        var command = ScanCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init()
        )
        let report = try command.run()
        XCTAssertEqual(report.missingKeys.map(\.value), ["Wrong table"])
        XCTAssertEqual(report.missingKeys.first?.table, "Errors")
    }

    /// Every finding counted in `failures` must be retrievable from the JSON,
    /// or an agent working from JSON can never reach a clean run.
    func testReportFailureCountMatchesEnumeratedFindings() throws {
        try writeSource("App/View.swift", """
            import SwiftUI
            let a = Text("Not in catalog")
            let b = Text("Untranslated")
            """)
        try writeCatalog("App/Localizable.xcstrings", keys: ["Untranslated": [:]])

        let target = Target(name: "App", sources: ["App"], catalogs: ["App/Localizable.xcstrings"])
        var command = ScanCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init()
        )
        let report = try command.run()

        let json = report.jsonValue
        let missing = json["missingKeys"]?.arrayValue?.count ?? 0
        let untranslated = json["untranslated"]?.arrayValue?.count ?? 0
        let diagnostics = json["diagnostics"]?.arrayValue?.count ?? 0
        XCTAssertEqual(report.failures, missing + untranslated + diagnostics)
        XCTAssertEqual(json["failures"]?.intValue, report.failures)
        XCTAssertGreaterThan(report.failures, 0)
    }

    func testScanWritesNothingUnlessAsked() throws {
        try writeSource("App/View.swift", #"import SwiftUI\nlet a = Text("Missing")"#)
        try writeCatalog("App/Localizable.xcstrings", keys: [:])

        let target = Target(name: "App", sources: ["App"], catalogs: ["App/Localizable.xcstrings"])
        var command = ScanCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(writeTemplates: false)
        )
        let report = try command.run()
        XCTAssertTrue(report.templatesWritten.isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains { $0.hasSuffix(".json") })
    }

    // MARK: - check

    /// One unreadable catalog must not deny a report on the healthy ones.
    func testCorruptCatalogDoesNotAbortTheRun() throws {
        try writeCatalog("Good/Localizable.xcstrings", keys: ["K": ["ja": "v"]])
        try writeSource("Bad/Localizable.xcstrings", "{ this is not json")

        let targets = [
            Target(name: "Good", sources: [], catalogs: ["Good/Localizable.xcstrings"]),
            Target(name: "Bad", sources: [], catalogs: ["Bad/Localizable.xcstrings"]),
        ]
        var command = CheckCommand(
            workspace: Workspace(configuration: configuration(targets: targets)),
            options: .init()
        )
        let report = try command.run()
        XCTAssertEqual(report.catalogs.count, 1)
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertTrue(report.diagnostics[0].path.contains("Bad"))
    }

    /// A language declared in configuration but absent from the catalog is 0%
    /// translated, not silently complete.
    func testDeclaredLanguageWithNoEntriesIsReported() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["K": ["ja": "v"]])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = CheckCommand(
            workspace: Workspace(configuration: configuration(targets: [target], languages: ["ja", "de"])),
            options: .init()
        )
        let report = try command.run()
        let german = report.catalogs[0].coverage.first { $0.language == "de" }
        XCTAssertEqual(german?.percent, 0)
        XCTAssertEqual(german?.missing, ["K"])
    }

    /// Stale keys are on their way out of the catalog; demanding translations
    /// for them is busywork Xcode itself does not ask for.
    func testStaleKeysAreExcludedFromCoverage() throws {
        let document = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object([
                "Live": .object([:]),
                "Retired": .object(["extractionState": .string("stale")]),
            ]),
        ])
        let url = root.appendingPathComponent("App/Localizable.xcstrings")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONWriter.text(document).write(to: url, atomically: true, encoding: .utf8)

        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = CheckCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init()
        )
        let report = try command.run()
        XCTAssertEqual(report.catalogs[0].staleKeys, ["Retired"])
        XCTAssertEqual(report.catalogs[0].coverage.first?.missing, ["Live"])
    }

    // MARK: - add

    /// A payload containing both "Save" and "save" must not create two keys
    /// that Xcode cannot generate symbols for.
    func testAddRejectsCaseCollisionsWithinOnePayload() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: [:])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = AddCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(languages: ["ja"])
        )
        let payload = TranslationPayload(
            catalog: "App/Localizable.xcstrings",
            language: "ja",
            entries: ["Save": .simple("保存"), "save": .simple("保存2")]
        )
        let report = try command.run(payload: payload, catalogPath: nil)
        XCTAssertEqual(report.conflicts.count, 1)

        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertEqual(catalog.keys.count, 1)
    }

    /// The template names its own catalog and language, so applying it cannot
    /// misfile translations.
    func testTemplateRoundTrip() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["Save": [:]])
        let templatePath = root.appendingPathComponent("t.json").path
        try TranslationPayload.writeTemplate(
            keys: ["Save"],
            catalog: "App/Localizable.xcstrings",
            language: "ja",
            to: templatePath
        )
        var payload = try TranslationPayload.load(
            from: Data(contentsOf: URL(fileURLWithPath: templatePath)),
            path: templatePath
        )
        XCTAssertEqual(payload.language, "ja")
        XCTAssertEqual(payload.catalog, "App/Localizable.xcstrings")
        XCTAssertTrue(payload.entries["Save"]?.isTodo == true)

        payload.entries["Save"] = .simple("保存")
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = AddCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init()
        )
        let report = try command.run(payload: payload, catalogPath: nil)
        XCTAssertEqual(report.language, "ja")

        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertEqual(catalog.value("Save", "ja"), "保存")
    }

    func testAddDryRunWritesNothing() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["Save": [:]])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = AddCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(languages: ["ja"], dryRun: true)
        )
        _ = try command.run(
            payload: TranslationPayload(catalog: nil, language: "ja", entries: ["Save": .simple("保存")]),
            catalogPath: "App/Localizable.xcstrings"
        )
        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertNil(catalog.value("Save", "ja"))
    }

    /// Writing a locale the catalog has never heard of is nearly always a typo,
    /// and the mistake is invisible afterwards because checks report it as done.
    func testUnknownLanguageIsRejected() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["Save": ["ja": "保存"]])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var configuration = self.configuration(targets: [target])
        configuration.languages = []
        var command = AddCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(languages: ["jp"])
        )
        XCTAssertThrowsError(try command.run(
            payload: TranslationPayload(catalog: nil, language: nil, entries: ["Save": .simple("x")]),
            catalogPath: "App/Localizable.xcstrings"
        )) { error in
            XCTAssertTrue("\(error)".contains("ja"), "\(error)")   // suggests the real code
        }
    }

    // MARK: - set

    func testSetRefusesToInventKeys() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["Goodbye": ["ja": "さようなら"]])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = SetCommand(
            workspace: Workspace(configuration: configuration(targets: [target])),
            options: .init(languages: ["ja"], createKeys: false)
        )
        XCTAssertThrowsError(
            try command.run(key: "Godbye", value: "x", catalogPath: "App/Localizable.xcstrings")
        ) { error in
            guard case SmithError.keyNotFound = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - lookup

    func testLookupExitsNonZeroWhenNothingMatches() throws {
        try writeCatalog("App/Localizable.xcstrings", keys: ["Save": ["ja": "保存"]])
        let target = Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])
        var command = LookupCommand(workspace: Workspace(configuration: configuration(targets: [target])))

        let hit = try command.run(queries: ["Save"], catalogPaths: nil)
        XCTAssertEqual(hit.failures, 0)

        let miss = try command.run(queries: ["Nothing like this at all"], catalogPaths: nil)
        XCTAssertEqual(miss.failures, 1)
    }
}
