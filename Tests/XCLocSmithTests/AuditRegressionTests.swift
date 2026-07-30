import XCTest
@testable import XCLocSmithKit

/// Audit regression tests. Every test here SHOULD pass and currently FAILS.
final class AuditRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// BUG 1: a catalog listed in two targets. A key referenced by target A is an
    /// "orphan" for target B, and prune --apply deletes it while claiming to have
    /// deleted something else.
    func testPruneSpansTargetsForSharedCatalogs() throws {
        var strings = ""
        var appBody = ""
        var widgetBody = ""
        for i in 0..<6 {
            strings += #""Shared \#(i)": {"localizations":{"ja":{"stringUnit":{"state":"translated","value":"x"}}}},"#
            appBody += "      Text(\"Shared \(i)\")\n"
            widgetBody += "      Text(\"Shared \(i)\")\n"
        }
        for name in ["App Only 1", "App Only 2"] {
            strings += #""\#(name)": {"localizations":{"ja":{"stringUnit":{"state":"translated","value":"x"}}}},"#
            appBody += "      Text(\"\(name)\")\n"
        }
        for name in ["Widget Only 1", "Widget Only 2"] {
            strings += #""\#(name)": {"localizations":{"ja":{"stringUnit":{"state":"translated","value":"x"}}}},"#
            widgetBody += "      Text(\"\(name)\")\n"
        }
        strings.removeLast()
        try write("Shared/Localizable.xcstrings", #"{"sourceLanguage":"en","version":"1.0","strings":{\#(strings)}}"#)
        try write("App/View.swift", "import SwiftUI\nstruct V: View {\n  var body: some View {\n    VStack {\n\(appBody)    }\n  }\n}\n")
        try write("Widget/W.swift", "import SwiftUI\nstruct W: View {\n  var body: some View {\n    VStack {\n\(widgetBody)    }\n  }\n}\n")

        var configuration = Configuration(root: root.path)
        configuration.languages = ["ja"]
        configuration.targets = [
            Target(name: "App", sources: ["App"], catalogs: ["Shared/Localizable.xcstrings"]),
            Target(name: "Widget", sources: ["Widget"], catalogs: ["Shared/Localizable.xcstrings"]),
        ]
        let command = PruneCommand(workspace: Workspace(configuration: configuration), options: .init(dryRun: false))
        let reports = try command.run()

        let catalog = try Catalog(path: root.appendingPathComponent("Shared/Localizable.xcstrings").path)
        // A key referenced by *any* target's source must survive.
        XCTAssertNotNil(catalog.strings["App Only 1"], "prune deleted a key App/View.swift references")
        XCTAssertNotNil(catalog.strings["Widget Only 1"], "prune deleted a key Widget/W.swift references")
        // And whatever the report says was removed must actually be gone.
        for key in reports.flatMap(\.changes).filter({ $0.action == "removed" }).map(\.key) {
            XCTAssertNil(catalog.strings[key], "report claims \"\(key)\" was removed but it is still on disk")
        }
    }

    /// BUG 2: a plural payload against a substitutions-based localization
    /// silently deletes the translated stringUnit without --flatten.
    func testPluralWriteDoesNotDestroySubstitutionStringUnit() throws {
        try write("App/Localizable.xcstrings", #"""
            {"sourceLanguage":"en","version":"1.0","strings":{"Found %#@count@":{"localizations":{"ja":{"stringUnit":{"state":"translated","value":"%#@count@を発見"},"substitutions":{"count":{"argNum":1,"formatSpecifier":"lld","variations":{"plural":{"other":{"stringUnit":{"state":"translated","value":"%lld件"}}}}}}}}}}}
            """#)
        var configuration = Configuration(root: root.path)
        configuration.languages = ["ja"]
        configuration.targets = [Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])]
        let command = AddCommand(workspace: Workspace(configuration: configuration), options: .init(languages: ["ja"]))
        let payload = TranslationPayload(
            catalog: "App/Localizable.xcstrings",
            language: "ja",
            entries: ["Found %#@count@": .plural(["other": "%lld件見つかった"])]
        )
        let report = try command.run(payload: payload, catalogPath: nil)

        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        let value = catalog.localization("Found %#@count@", "ja")?["stringUnit"]?
            .objectValue?["value"]?.stringValue
        // Either the write was refused (report.refusals) or the stringUnit survived.
        if report.refusals.isEmpty {
            XCTAssertEqual(value, "%#@count@を発見",
                "plural write destroyed the substitution-referencing stringUnit without --flatten")
        }
    }

    /// BUG 3: an unknown --lang on scan is silently swallowed, so scan reports
    /// clean instead of erroring like check does.
    func testScanRejectsUnknownLanguage() throws {
        try write("App/View.swift", "import SwiftUI\nstruct V: View { var body: some View { Text(\"Hello\") } }\n")
        try write("App/Localizable.xcstrings", #"{"sourceLanguage":"en","version":"1.0","strings":{"Hello":{}}}"#)
        var configuration = Configuration(root: root.path)
        configuration.languages = ["ja"]
        configuration.targets = [Target(name: "App", sources: ["App"], catalogs: ["App/Localizable.xcstrings"])]

        var real = ScanCommand(workspace: Workspace(configuration: configuration), options: .init(languages: ["ja"]))
        let realReport = try real.run()
        XCTAssertEqual(realReport.untranslated.count, 1)

        var bogus = ScanCommand(workspace: Workspace(configuration: configuration), options: .init(languages: ["zz"]))
        // Must throw (like check does) — silently reporting clean hides the typo.
        XCTAssertThrowsError(try bogus.run(), "scan with an unknown language reported clean instead of erroring")
    }

    /// BUG 4: `let title = "…"` is a local constant, not a UIKit assignment,
    /// and must not be reported as a localization bypass.
    func testLocalConstantIsNotAUIKitBypass() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    let title = "Settings Header"
                    return Text(verbatim: title)
                }
            }
            """
        let file = AnalyzedSource(path: "/tmp/T.swift", displayPath: "T.swift", text: source)
        let result = SourceAnalyzer.analyze(
            file: file,
            discovered: DiscoveredLocalizables(),
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
        XCTAssertTrue(
            result.bypasses.filter { $0.reason.contains(".title") }.isEmpty,
            "a `let title =` local constant was reported as a UIKit .title assignment"
        )
    }

    /// BUG 5: an interpolated literal containing a literal `%` must match the
    /// key Xcode extracts, which escapes it as `%%`.
    func testInterpolationWithLiteralPercentMatchesExtractedKey() {
        let literals = SwiftLexer.lex(#"Text("Battery at \(pct)%")"#).literals
        let pattern = literals.first?.formatPattern
        XCTAssertNotNil(pattern)
        let key = "Battery at %lld%%"   // what xcstringstool extract writes
        let regex = try? NSRegularExpression(pattern: "^" + (pattern ?? "") + "$")
        let range = NSRange(key.startIndex..., in: key)
        XCTAssertNotNil(
            regex?.firstMatch(in: key, range: range),
            "pattern \(pattern ?? "nil") does not match Xcode's extracted key \(key)"
        )
    }
}
