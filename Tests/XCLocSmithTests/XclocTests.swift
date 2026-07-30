import XCTest
@testable import XCLocSmithKit

final class XclocTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - trans-unit ids

    /// Xcode encodes variations by appending a separator and a configuration
    /// path, so one catalog key becomes several units.
    func testTransUnitKeyParsing() {
        XCTAssertEqual(TransUnitKey(id: "Hello").key, "Hello")
        XCTAssertEqual(TransUnitKey(id: "Hello").configuration, .simple)

        let plural = TransUnitKey(id: "%lld items|==|plural.one")
        XCTAssertEqual(plural.key, "%lld items")
        XCTAssertEqual(plural.configuration, .plural(category: "one"))

        let device = TransUnitKey(id: "Tap here|==|device.iphone")
        XCTAssertEqual(device.configuration, .device(name: "iphone"))

        let substitution = TransUnitKey(id: "Found %#@count@|==|count.plural.other")
        XCTAssertEqual(substitution.key, "Found %#@count@")
        XCTAssertEqual(substitution.configuration, .substitutionPlural(name: "count", category: "other"))

        let qualified = TransUnitKey(id: "K|==|substitutions.count.plural.few")
        XCTAssertEqual(qualified.configuration, .substitutionPlural(name: "count", category: "few"))
    }

    /// A shape we do not understand must be reported, never guessed at: writing
    /// a translation into the wrong variation is invisible afterwards.
    func testUnknownConfigurationIsUnsupportedRatherThanGuessed() {
        let unit = TransUnitKey(id: "K|==|width.compact.plural.one")
        XCTAssertEqual(unit.key, "K")
        guard case .unsupported = unit.configuration else {
            return XCTFail("expected .unsupported, got \(unit.configuration)")
        }
    }

    // MARK: - XLIFF parsing

    func testParsesFilesUnitsAndAttributes() throws {
        let document = try XLIFFParser.parse(data: Data(sampleXLIFF.utf8), path: "ja.xliff")
        XCTAssertEqual(document.files.count, 2)

        let localizable = document.files[0]
        XCTAssertEqual(localizable.table, "Localizable")
        XCTAssertEqual(localizable.sourceLanguage, "en")
        XCTAssertEqual(localizable.targetLanguage, "ja")

        let welcome = localizable.units[0]
        XCTAssertEqual(welcome.id, "Welcome")
        XCTAssertEqual(welcome.source, "Welcome")
        XCTAssertEqual(welcome.target, "ようこそ")
        XCTAssertEqual(welcome.note, "A greeting.")
        XCTAssertTrue(welcome.isTranslated)

        let machine = localizable.units[1]
        XCTAssertEqual(machine.stateQualifier, "leveraged-mt")
        XCTAssertTrue(machine.isMachineTranslated)

        let untranslated = localizable.units[2]
        XCTAssertNil(untranslated.target)
        XCTAssertFalse(untranslated.isTranslated)

        XCTAssertEqual(document.files[1].table, "Errors")
    }

    /// Xcode names the `<file>` after the table with a `.strings` extension even
    /// when the strings came from a catalog.
    func testTableIsDerivedFromTheFileOriginal() {
        func table(_ original: String) -> String {
            XLIFFFile(original: original, sourceLanguage: "en", targetLanguage: "ja", datatype: nil, units: []).table
        }
        XCTAssertEqual(table("MyApp/Localizable.strings"), "Localizable")
        XCTAssertEqual(table("MyApp/Buttons.strings"), "Buttons")
        XCTAssertEqual(table("MyApp/Localizable.xcstrings"), "Localizable")
        XCTAssertEqual(table("InfoPlist.strings"), "InfoPlist")
    }

    func testMalformedXMLIsRejected() {
        XCTAssertThrowsError(try XLIFFParser.parse(data: Data("<xliff><file>".utf8), path: "bad.xliff"))
    }

    /// Machine translation is imported as needs_review whatever its state says,
    /// because a machine translation marked "translated" is one nobody will
    /// look at again.
    func testStateMapping() {
        XCTAssertEqual(XLIFFState.catalogState(state: "translated", qualifier: nil), .translated)
        XCTAssertEqual(XLIFFState.catalogState(state: nil, qualifier: nil), .translated)
        XCTAssertEqual(XLIFFState.catalogState(state: "needs-translation", qualifier: nil), .new)
        XCTAssertEqual(XLIFFState.catalogState(state: "needs-review-translation", qualifier: nil), .needsReview)
        XCTAssertEqual(XLIFFState.catalogState(state: "translated", qualifier: "leveraged-mt"), .needsReview)
        XCTAssertEqual(XLIFFState.catalogState(state: "final", qualifier: "mt-suggestion"), .needsReview)
    }

    // MARK: - Bundle

    func testReadsBundleStructure() throws {
        let bundle = try makeBundle()
        let catalog = try LocalizationCatalog.load(path: bundle.path)
        XCTAssertEqual(catalog.targetLanguage, "ja")
        XCTAssertEqual(catalog.contents.developmentRegion, "en")
        XCTAssertEqual(catalog.contents.toolName, "Xcode")
        XCTAssertEqual(catalog.documents.count, 1)
    }

    /// Localizers routinely return the bare XLIFF rather than the bundle.
    func testAcceptsABareXLIFF() throws {
        let path = root.appendingPathComponent("ja.xliff")
        try sampleXLIFF.write(to: path, atomically: true, encoding: .utf8)
        let catalog = try LocalizationCatalog.load(path: path.path)
        XCTAssertEqual(catalog.targetLanguage, "ja")
        XCTAssertEqual(catalog.documents.first?.files.count, 2)
    }

    // MARK: - check

    func testCheckFindsTheDefectsThatMatter() throws {
        let bundle = try makeBundle()
        let workspace = Workspace(configuration: try projectConfiguration())
        let command = XclocCheckCommand(workspace: workspace)
        let report = try command.run(bundlePath: bundle.path)

        // %lld in the source, %@ in the translation: a crash, not a typo.
        XCTAssertEqual(report.formatMismatches.count, 1)
        XCTAssertTrue(report.formatMismatches[0].unitID.contains("%lld items"))

        // ja needs `other`; the bundle only carries `one`.
        XCTAssertEqual(report.pluralGaps.count, 1)
        XCTAssertTrue(report.pluralGaps[0].problem.contains("other"))

        XCTAssertEqual(report.machineTranslated.count, 1)
        XCTAssertEqual(report.untranslated.count, 1)
        XCTAssertTrue(report.unknownKeys.contains { $0.unitID == "Ghost key" })
        XCTAssertEqual(report.failures, report.formatMismatches.count + report.pluralGaps.count)
        _ = workspace
    }

    func testCheckReportsLanguageMetadataDisagreement() throws {
        let bundle = try makeBundle(targetLocaleInContents: "de")
        let command = XclocCheckCommand(workspace: Workspace(configuration: try projectConfiguration()))
        let report = try command.run(bundlePath: bundle.path)
        XCTAssertEqual(report.metadataProblems.count, 2)
        XCTAssertGreaterThan(report.failures, 0)
    }

    // MARK: - apply

    func testApplyWritesTranslationsWithoutDestroyingStructure() throws {
        let bundle = try makeBundle()
        let command = XclocApplyCommand(
            workspace: Workspace(configuration: try projectConfiguration()),
            options: .init(dryRun: false)
        )
        _ = try command.run(bundlePath: bundle.path)

        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertEqual(catalog.value("Welcome", "ja"), "ようこそ")

        // Machine translation lands as needs_review.
        let save = catalog.localization("Save", "ja")?["stringUnit"]?.objectValue
        XCTAssertEqual(save?["state"]?.stringValue, "needs_review")

        // The plural case is written as a variation, not flattened.
        let plural = catalog.localization("%lld items", "ja")?["variations"]?["plural"]?["one"]
        XCTAssertEqual(plural?["stringUnit"]?["value"]?.stringValue, "%@個")

        // The substitution survives and receives its plural case.
        let substitution = catalog.substitutions("Found %#@count@", "ja")["count"]
        XCTAssertEqual(
            substitution?["variations"]?["plural"]?["other"]?["stringUnit"]?["value"]?.stringValue,
            "%lld件"
        )
        XCTAssertEqual(substitution?["formatSpecifier"]?.stringValue, "lld")

        // The Errors table went to the Errors catalog.
        let errors = try Catalog(path: root.appendingPathComponent("App/Errors.xcstrings").path)
        XCTAssertEqual(errors.value("Disk full", "ja"), "ディスクがいっぱいです")
    }

    /// An XLIFF translates a catalog; it does not extend one. A unit for a key
    /// the project does not have is a stale or foreign unit, not a new string.
    func testApplyNeverInventsKeys() throws {
        let bundle = try makeBundle()
        let command = XclocApplyCommand(
            workspace: Workspace(configuration: try projectConfiguration()),
            options: .init(dryRun: false)
        )
        let reports = try command.run(bundlePath: bundle.path)
        XCTAssertTrue(reports.contains { $0.refusals.contains { $0.key == "Ghost key" } })

        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertNil(catalog.strings["Ghost key"])
    }

    func testApplyDryRunWritesNothing() throws {
        let bundle = try makeBundle()
        let command = XclocApplyCommand(
            workspace: Workspace(configuration: try projectConfiguration()),
            options: .init(dryRun: true)
        )
        _ = try command.run(bundlePath: bundle.path)
        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertNil(catalog.value("Welcome", "ja"))
    }

    // MARK: - Fixtures

    private func projectConfiguration() throws -> Configuration {
        var configuration = Configuration(root: root.path)
        configuration.languages = ["ja"]
        configuration.targets = [Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings", "App/Errors.xcstrings"]
        )]

        let appDirectory = root.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        let localizable = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object([
                "Welcome": .object([:]),
                "Save": .object([:]),
                "%lld items": .object([:]),
                "Only in project": .object([:]),
                "Found %#@count@": .object(["localizations": .object(["ja": .object([
                    "stringUnit": .object(["state": .string("translated"), "value": .string("%#@count@")]),
                    "substitutions": .object(["count": .object([
                        "argNum": .number("1"),
                        "formatSpecifier": .string("lld"),
                    ])]),
                ])])]),
            ]),
        ])
        try JSONWriter.text(localizable)
            .write(to: appDirectory.appendingPathComponent("Localizable.xcstrings"), atomically: true, encoding: .utf8)

        let errors = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object(["Disk full": .object([:])]),
        ])
        try JSONWriter.text(errors)
            .write(to: appDirectory.appendingPathComponent("Errors.xcstrings"), atomically: true, encoding: .utf8)

        return configuration
    }

    private func makeBundle(targetLocaleInContents: String = "ja") throws -> URL {
        let bundle = root.appendingPathComponent("ja.xcloc")
        let localized = bundle.appendingPathComponent(LocalizationCatalog.localizedContentsDirectory)
        try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)

        let contents = JSONValue.object([
            "developmentRegion": .string("en"),
            "targetLocale": .string(targetLocaleInContents),
            "toolInfo": .object([
                "toolName": .string("Xcode"),
                "toolBuildNumber": .string("17A1"),
            ]),
            "version": .string("1.0"),
        ])
        try JSONWriter.text(contents, style: .plain)
            .write(to: bundle.appendingPathComponent(LocalizationCatalog.contentsFileName),
                   atomically: true, encoding: .utf8)
        try sampleXLIFF.write(to: localized.appendingPathComponent("ja.xliff"), atomically: true, encoding: .utf8)
        return bundle
    }

    private let sampleXLIFF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2">
          <file original="App/Localizable.strings" source-language="en" target-language="ja" datatype="plaintext">
            <header><tool tool-id="com.apple.dt.xcode" tool-name="Xcode"/></header>
            <body>
              <trans-unit id="Welcome" xml:space="preserve">
                <source>Welcome</source>
                <target>ようこそ</target>
                <note>A greeting.</note>
              </trans-unit>
              <trans-unit id="Save" xml:space="preserve">
                <source>Save</source>
                <target state="translated" state-qualifier="leveraged-mt">保存</target>
              </trans-unit>
              <trans-unit id="Untranslated thing" xml:space="preserve">
                <source>Untranslated thing</source>
              </trans-unit>
              <trans-unit id="%lld items|==|plural.one" xml:space="preserve">
                <source>%lld item</source>
                <target>%@個</target>
              </trans-unit>
              <trans-unit id="Found %#@count@|==|count.plural.other" xml:space="preserve">
                <source>%lld found</source>
                <target>%lld件</target>
              </trans-unit>
              <trans-unit id="Ghost key" xml:space="preserve">
                <source>Ghost key</source>
                <target>幽霊</target>
              </trans-unit>
            </body>
          </file>
          <file original="App/Errors.strings" source-language="en" target-language="ja" datatype="plaintext">
            <body>
              <trans-unit id="Disk full" xml:space="preserve">
                <source>Disk full</source>
                <target>ディスクがいっぱいです</target>
              </trans-unit>
            </body>
          </file>
        </xliff>
        """
}
