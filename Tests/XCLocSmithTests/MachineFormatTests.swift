import XCTest
@testable import XCLocSmithKit

/// SARIF and GitHub annotation output.
///
/// Both render from `Report.findings` rather than from the reports themselves,
/// so the invariant worth testing is not the shape of the JSON — it is that
/// the number of findings equals the number the run said it had. A CI
/// annotation stream quietly shorter than the terminal output is the failure
/// mode here, and it is invisible: the build goes red either way.
final class MachineFormatTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The counts must agree

    func testEveryCheckFindingIsAccountedForInTheCounts() throws {
        let report = try check(try busyCatalog(), languages: ["en", "de", "ja"])
        XCTAssertGreaterThan(report.findings.count, 0)
        XCTAssertEqual(report.findings.count, report.failures + report.advisories)
    }

    func testEveryScanFindingIsAccountedForInTheCounts() throws {
        try write("App/View.swift", "Text(\"Not in any catalog\")")
        _ = try makeCatalog(strings: [
            "Unused key": localized(["en": "Unused key", "de": "Unbenutzt"]),
        ])
        var configuration = baseConfiguration()
        configuration.languages = ["de"]
        let report = try ScanCommand(
            workspace: Workspace(configuration: configuration),
            options: .init()
        ).run()

        XCTAssertGreaterThan(report.findings.count, 0)
        XCTAssertEqual(report.findings.count, report.failures + report.advisories)
    }

    /// A failure must never be annotated as a warning: the whole point of the
    /// SARIF upload is that code scanning can be set to block on errors.
    func testLevelsFollowTheFailureAndAdvisorySplit() throws {
        let report = try check(try busyCatalog(), languages: ["en", "de", "ja"])
        let errors = report.findings.filter { $0.level == .error }.count
        XCTAssertEqual(errors, report.failures)
    }

    // MARK: - SARIF

    func testSarifIsWellFormedAndDeclaresEveryRuleItUses() throws {
        let report = try check(try busyCatalog(), languages: ["en", "de", "ja"])
        let text = MachineRenderer(configuration: baseConfiguration())
            .sarif(report, toolVersion: "1.2.3")
        let document = try JSONParser.parse(Data(text.utf8))

        XCTAssertEqual(document.objectValue?["version"]?.stringValue, "2.1.0")
        let run = try XCTUnwrap(document.objectValue?["runs"]?.arrayValue?.first?.objectValue)
        let driver = try XCTUnwrap(run["tool"]?.objectValue?["driver"]?.objectValue)
        XCTAssertEqual(driver["version"]?.stringValue, "1.2.3")

        let results = try XCTUnwrap(run["results"]?.arrayValue)
        XCTAssertEqual(results.count, report.findings.count)

        let declared = Set(
            (driver["rules"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
        )
        let used = Set(results.compactMap { $0.objectValue?["ruleId"]?.stringValue })
        XCTAssertEqual(used.subtracting(declared), [], "every ruleId must be in the rule table")
    }

    /// SARIF regions are 1-based; `startLine: 0` makes the whole upload invalid,
    /// so a finding with no line carries no region rather than a zero.
    func testAFindingWithNoLineCarriesNoRegion() throws {
        let finding = Finding(rule: "configuration", level: .error, message: "boom", file: "App/x.swift")
        var report = CheckReport()
        report.diagnostics = [DiagnosticError(path: "App/x.swift", message: "boom")]
        _ = finding

        let text = MachineRenderer(configuration: baseConfiguration()).sarif(report, toolVersion: "1")
        let document = try JSONParser.parse(Data(text.utf8))
        let result = try XCTUnwrap(
            document.objectValue?["runs"]?.arrayValue?.first?
                .objectValue?["results"]?.arrayValue?.first?.objectValue
        )
        let location = try XCTUnwrap(
            result["locations"]?.arrayValue?.first?.objectValue?["physicalLocation"]?.objectValue
        )
        XCTAssertNil(location["region"])
    }

    // MARK: - GitHub

    /// A newline inside a message silently truncates the annotation at the
    /// newline, and a `::` can close the command early.
    func testWorkflowCommandsEscapeTheirPayload() throws {
        let catalog = try makeCatalog(strings: [
            "warn.line": localized(["en": "Line one\nline two: %@", "de": "Zeile"]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        let output = MachineRenderer(configuration: baseConfiguration()).github(report)

        XCTAssertFalse(output.isEmpty)
        // One annotation per line, whatever the messages contain.
        XCTAssertEqual(output.split(separator: "\n").count, report.findings.count)
        XCTAssertTrue(output.contains("%0A"), output)
    }

    func testACleanRunPrintsNothing() throws {
        let catalog = try makeCatalog(strings: [
            "app.ok": localized(["en": "OK", "de": "OK"]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(MachineRenderer(configuration: baseConfiguration()).github(report), "")
    }

    /// An annotation without a line lands on row one of a four-thousand-line
    /// JSON file, which is worse than useless on a diff.
    func testACatalogFindingIsPlacedOnTheLineItsKeyIsDeclaredOn() throws {
        let catalog = try makeCatalog(strings: [
            "a.first": localized(["en": "First"]),
            "z.last": localized(["en": "Last"]),
        ])
        let index = try XCTUnwrap(CatalogLineIndex(path: catalog.path))
        let text = try String(contentsOf: catalog, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        let first = try XCTUnwrap(index.line(of: "a.first"))
        XCTAssertTrue(lines[first - 1].contains("\"a.first\""), String(lines[first - 1]))
        let last = try XCTUnwrap(index.line(of: "z.last"))
        XCTAssertTrue(lines[last - 1].contains("\"z.last\""), String(lines[last - 1]))
    }

    /// The catalog format escapes forward slashes, which no other JSON writer
    /// does, and keys carrying a path are common in `InfoPlist.xcstrings`.
    func testTheLineIndexUnescapesKeysTheWayTheWriterEscapesThem() throws {
        let keys = ["path/to/thing", "line\nbreak", "tab\there", "quote\"inside", "emoji 🛁"]
        var strings: [String: JSONValue] = [:]
        for key in keys { strings[key] = localized(["en": key]) }
        let catalog = try makeCatalog(strings: strings)

        let index = try XCTUnwrap(CatalogLineIndex(path: catalog.path))
        // Every one of them, including the newline: the writer escapes it as
        // the two characters `\n`, so the key stays on a single line of the
        // file and there is a line to find.
        for key in keys {
            XCTAssertNotNil(index.line(of: key), "no line for \(key.debugDescription)")
        }
        XCTAssertEqual(Set(keys.compactMap { index.line(of: $0) }).count, keys.count)
    }

    /// A key named after a structural field or a language code must resolve to
    /// its own declaration, not to the first structural line that spells it — a
    /// key literally called "en" used to land on the `"en" : {` inside a
    /// different key's localizations. Keys sit at exactly one indent level.
    func testAKeyNamedLikeAStructuralFieldIsLocatedOnItsOwnLine() throws {
        let catalog = try makeCatalog(strings: [
            "app.first": localized(["en": "First"]),
            "en": localized(["en": "English"]),
            "localizations": localized(["en": "Localizations"]),
        ])
        let index = try XCTUnwrap(CatalogLineIndex(path: catalog.path))
        let lines = try String(contentsOf: catalog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)

        for key in ["app.first", "en", "localizations"] {
            let line = try XCTUnwrap(index.line(of: key), key)
            XCTAssertTrue(
                lines[line - 1].hasPrefix("    \"\(key)\""),
                "\(key) resolved to: \(lines[line - 1])"
            )
        }
    }

    /// GitHub's ingestion requires `fullDescription.text` and `help.text` on
    /// every rule, and refuses empty strings for required properties.
    func testSarifRulesCarryTheDescriptionsGitHubRequires() throws {
        let report = try check(try busyCatalog(), languages: ["en", "de", "ja"])
        let text = MachineRenderer(configuration: baseConfiguration())
            .sarif(report, toolVersion: "1")
        let document = try JSONParser.parse(Data(text.utf8))
        let rules = try XCTUnwrap(
            document.objectValue?["runs"]?.arrayValue?.first?.objectValue?["tool"]?
                .objectValue?["driver"]?.objectValue?["rules"]?.arrayValue
        )
        XCTAssertFalse(rules.isEmpty)
        for rule in rules {
            let fields = try XCTUnwrap(rule.objectValue)
            for property in ["shortDescription", "fullDescription", "help"] {
                let text = fields[property]?.objectValue?["text"]?.stringValue
                XCTAssertNotEqual(text ?? "", "", "\(property) missing or empty")
            }
        }
    }

    /// The SARIF spec forbids `uriBaseId` beside an absolute URI, and a
    /// relative reference must not start with "/". An absolute path — a catalog
    /// outside the project, a bundle named absolutely — becomes a file: URI on
    /// its own. Relative paths percent-encode into valid URI references.
    func testUrisAreValidAndAbsolutePathsCarryNoBaseId() throws {
        var report = CheckReport()
        report.diagnostics = [
            DiagnosticError(path: "/outside/My App/Localizable.xcstrings", message: "boom"),
            DiagnosticError(path: "App Dir/Localizable.xcstrings", message: "boom"),
        ]
        let text = MachineRenderer(configuration: baseConfiguration()).sarif(report, toolVersion: "1")
        let document = try JSONParser.parse(Data(text.utf8))
        let results = try XCTUnwrap(
            document.objectValue?["runs"]?.arrayValue?.first?.objectValue?["results"]?.arrayValue
        )
        let artifacts = try results.map {
            try XCTUnwrap(
                $0.objectValue?["locations"]?.arrayValue?.first?.objectValue?["physicalLocation"]?
                    .objectValue?["artifactLocation"]?.objectValue
            )
        }
        let absolute = try XCTUnwrap(artifacts.first { $0["uri"]?.stringValue?.hasPrefix("file://") == true })
        XCTAssertEqual(absolute["uri"]?.stringValue, "file:///outside/My%20App/Localizable.xcstrings")
        XCTAssertNil(absolute["uriBaseId"])
        let relative = try XCTUnwrap(artifacts.first { $0["uri"]?.stringValue?.hasPrefix("file://") == false })
        XCTAssertEqual(relative["uri"]?.stringValue, "App%20Dir/Localizable.xcstrings")
        XCTAssertEqual(relative["uriBaseId"]?.stringValue, "%SRCROOT%")
    }

    // MARK: - Format selection

    func testJsonAndFormatMustAgree() throws {
        XCTAssertEqual(OutputFormat(rawValue: "sarif"), .sarif)
        XCTAssertNil(OutputFormat(rawValue: "yaml"))
    }

    // MARK: - Helpers

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }

    private func localized(_ values: [String: String]) -> JSONValue {
        .object(["localizations": .object(values.mapValues { unit($0) })])
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A catalog exercising as many rules at once as possible, so the counting
    /// invariant is tested against a mixture rather than one finding.
    private func busyCatalog() throws -> URL {
        try makeCatalog(strings: [
            // missing ja, and identical in de
            "app.title": localized(["en": "Furolog", "de": "Furolog"]),
            // format mismatch in de
            "count.items": localized(["en": "%lld items", "de": "Einträge"]),
            // duplicate source, translated two ways
            "a.remove": localized(["en": "Remove", "de": "Löschen", "ja": "削除"]),
            "b.remove": localized(["en": "Remove", "de": "Entfernen", "ja": "削除"]),
            // near-duplicate
            "one.heading": localized(["en": "Heart Rate", "de": "Herzfrequenz", "ja": "心拍数"]),
            "two.heading": localized(["en": "Heart rates", "de": "Herzfrequenzen", "ja": "心拍数一覧"]),
            // stale
            "gone.key": .object([
                "extractionState": .string("stale"),
                "localizations": .object(["en": unit("Gone")]),
            ]),
        ])
    }

    private func makeCatalog(strings: [String: JSONValue]) throws -> URL {
        let url = root.appendingPathComponent("App/Localizable.xcstrings")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        try JSONWriter.text(document).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func baseConfiguration() -> Configuration {
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings"]
        )]
        return configuration
    }

    private func check(_ catalog: URL, languages: [String]) throws -> CheckReport {
        var configuration = baseConfiguration()
        configuration.languages = languages
        return try CheckCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(languages: languages)
        ).run()
    }
}
