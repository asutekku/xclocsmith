import XCTest
@testable import XCLocSmithKit

/// Renaming a key, in the catalog and at every call site.
///
/// This command exists to fix a data-loss bug and is itself the most dangerous
/// thing in the tool: it rewrites source files and moves the only copy of a
/// string's English. The tests below are mostly about what it must *not* do —
/// merge two keys, drop a plural, rewrite a literal in another table, or edit
/// half a project and stop.
final class RenameTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The catalog

    private func makeCatalog(
        _ strings: [String: JSONValue],
        named name: String = "Localizable.xcstrings",
        source: String = "en"
    ) throws -> String {
        let path = root.appendingPathComponent("App/\(name)")
        let document = JSONValue.object([
            "sourceLanguage": .string(source),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        try JSONWriter.text(document, style: .plain).write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func entry(
        comment: String? = nil,
        extractionState: String? = nil,
        localizations: [String: JSONValue] = [:]
    ) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let comment { fields["comment"] = .string(comment) }
        if let extractionState { fields["extractionState"] = .string(extractionState) }
        if !localizations.isEmpty { fields["localizations"] = .object(localizations) }
        return .object(fields)
    }

    private func unit(_ value: String, _ state: String = "translated") -> JSONValue {
        .object(["stringUnit": .object(["state": .string(state), "value": .string(value)])])
    }

    private func load(_ path: String) throws -> Catalog {
        try XCTUnwrap(Catalog(path: path, displayPath: "App/Localizable.xcstrings"))
    }

    /// The whole point: the English that was only in the key has to survive.
    func testTheKeyBecomesTheSourceLanguageValue() throws {
        let sentence = "Each session is divided into segments and shown in the flow bar"
        let path = try makeCatalog([sentence: entry(
            comment: "Explanation of the segment types.",
            localizations: ["ja": unit("各セッション"), "de": unit("Jede Sitzung")]
        )])
        var catalog = try load(path)

        try catalog.rename(sentence, to: "session.segments.explanation")

        XCTAssertNil(catalog.strings[sentence])
        XCTAssertEqual(catalog.value("session.segments.explanation", "en"), sentence)
        XCTAssertEqual(catalog.value("session.segments.explanation", "ja"), "各セッション")
        XCTAssertEqual(catalog.value("session.segments.explanation", "de"), "Jede Sitzung")
        XCTAssertEqual(catalog.comment("session.segments.explanation"), "Explanation of the segment types.")
    }

    /// A key that already has its own English keeps it; inventing a second one
    /// from the key would overwrite the real source string.
    func testAnExistingSourceValueIsNotOverwritten() throws {
        let path = try makeCatalog(["old.key": entry(
            localizations: ["en": unit("The real English"), "fr": unit("Le vrai anglais")]
        )])
        var catalog = try load(path)

        try catalog.rename("old.key", to: "new.key")

        XCTAssertEqual(catalog.value("new.key", "en"), "The real English")
        XCTAssertEqual(catalog.value("new.key", "fr"), "Le vrai anglais")
    }

    /// A pluralised source has no flat value. Asking for one, finding nil and
    /// concluding "the English was only in the key" would replace four plural
    /// rows with a single string.
    func testAPluralisedSourceIsNotFlattened() throws {
        let plural = JSONValue.object(["variations": .object(["plural": .object([
            "one": unit("%lld item"),
            "other": unit("%lld items"),
        ])])])
        let path = try makeCatalog(["%lld items": entry(localizations: ["en": plural])])
        var catalog = try load(path)

        try catalog.rename("%lld items", to: "inventory.itemCount")

        let variations = catalog.localization("inventory.itemCount", "en")?["variations"]
        XCTAssertNotNil(variations, "the plural variations were destroyed")
        XCTAssertNil(catalog.localization("inventory.itemCount", "en")?["stringUnit"])
    }

    func testDeviceVariationsSurvive() throws {
        let device = JSONValue.object(["variations": .object(["device": .object([
            "iphone": unit("Tap"),
            "mac": unit("Click"),
        ])])])
        let path = try makeCatalog(["action.tap": entry(localizations: ["en": device])])
        var catalog = try load(path)

        try catalog.rename("action.tap", to: "action.activate")

        XCTAssertNotNil(catalog.localization("action.activate", "en")?["variations"])
    }

    func testExtractionStateTravelsWithTheKey() throws {
        let path = try makeCatalog(["Some long key here now": entry(
            extractionState: "manual",
            localizations: ["ja": unit("これ")]
        )])
        var catalog = try load(path)

        try catalog.rename("Some long key here now", to: "some.key")

        XCTAssertEqual(catalog.extractionState("some.key"), .manual)
    }

    // MARK: - Refusals

    /// Merging two strings is not a rename, and which translations survive is
    /// not something this can decide.
    func testRenamingOntoAnExistingKeyIsRefused() throws {
        let path = try makeCatalog([
            "old.key": entry(localizations: ["ja": unit("A")]),
            "new.key": entry(localizations: ["ja": unit("B")]),
        ])
        var catalog = try load(path)

        XCTAssertThrowsError(try catalog.rename("old.key", to: "new.key"))
        // And nothing moved.
        XCTAssertEqual(catalog.value("old.key", "ja"), "A")
        XCTAssertEqual(catalog.value("new.key", "ja"), "B")
    }

    func testRenamingAKeyThatDoesNotExistIsRefused() throws {
        let path = try makeCatalog(["a.key": entry(localizations: ["ja": unit("A")])])
        var catalog = try load(path)
        XCTAssertThrowsError(try catalog.rename("nope", to: "new.key"))
    }

    func testRenamingToItselfIsRefused() throws {
        let path = try makeCatalog(["a.key": entry(localizations: ["ja": unit("A")])])
        var catalog = try load(path)
        XCTAssertThrowsError(try catalog.rename("a.key", to: "a.key"))
    }

    /// Keys differing only by case break Xcode's symbol generation, and this
    /// command exists to leave a project in better shape than it found it.
    func testACaseOnlyClashIsRefused() throws {
        let path = try makeCatalog([
            "Some quite long key to rename": entry(localizations: ["ja": unit("A")]),
            "Session.Segments": entry(localizations: ["ja": unit("B")]),
        ])
        let report = try? RenameCommand(
            workspace: workspace(),
            options: .init(apply: false, updateSources: false)
        ).run(from: "Some quite long key to rename", to: "session.segments", catalogPath: path)

        XCTAssertNil(report, "a case-only clash with an existing key must be refused")
    }

    // MARK: - Through the command

    private func workspace() -> Workspace {
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings"]
        )]
        return Workspace(configuration: configuration)
    }

    private func writeSource(_ name: String, _ body: String) throws {
        try body.write(
            to: root.appendingPathComponent("App/\(name)"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("App/\(name)"), encoding: .utf8)
    }

    /// Reporting by default. The risk of this command is a half-understood edit
    /// across a catalog and a dozen files, so the default run writes nothing.
    func testWithoutApplyNothingIsWritten() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View { var body: some View { Text("\(sentence)") } }
        """)

        let report = try RenameCommand(workspace: workspace(), options: .init(apply: false))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        XCTAssertEqual(report.rewrites.count, 1)
        XCTAssertEqual(report.languagesCarried, ["ja"])
        XCTAssertTrue(report.movesEnglishIntoCatalog)
        XCTAssertTrue(try source("View.swift").contains(sentence), "the source was rewritten by a report-only run")
    }

    func testApplyRewritesTheCallSiteAndTheCatalog() throws {
        let sentence = "Each session is divided into segments here"
        let path = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View {
            var body: some View { Text("\(sentence)") }
        }
        """)

        let report = try RenameCommand(workspace: workspace(), options: .init(apply: true))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        XCTAssertEqual(report.failures, 0)
        let rewritten = try source("View.swift")
        XCTAssertTrue(rewritten.contains("Text(\"session.segments\")"), rewritten)
        XCTAssertFalse(rewritten.contains(sentence), rewritten)

        let catalog = try load(path)
        XCTAssertEqual(catalog.value("session.segments", "en"), sentence)
        XCTAssertEqual(catalog.value("session.segments", "ja"), "各")
    }

    /// Several call sites in one file: the offsets of the earlier ones must
    /// still be valid after the later ones have shifted the text.
    func testEveryCallSiteInAFileIsRewritten() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    Text("\(sentence)")
                    Text("unrelated string that is quite long")
                    Text("\(sentence)")
                }
            }
        }
        """)

        let report = try RenameCommand(workspace: workspace(), options: .init(apply: true))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        XCTAssertEqual(report.rewrites.count, 2)
        let rewritten = try source("View.swift")
        XCTAssertEqual(rewritten.components(separatedBy: "\"session.segments\"").count - 1, 2, rewritten)
        XCTAssertTrue(rewritten.contains("unrelated string that is quite long"), "an unrelated literal was touched")
    }

    /// A string that merely *contains* the key is not the key.
    func testASupersetLiteralIsNotRewritten() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                VStack {
                    Text("\(sentence)")
                    Text("\(sentence) and then some more text")
                }
            }
        }
        """)

        _ = try RenameCommand(workspace: workspace(), options: .init(apply: true))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        let rewritten = try source("View.swift")
        XCTAssertTrue(rewritten.contains("\(sentence) and then some more text"), rewritten)
        XCTAssertTrue(rewritten.contains("Text(\"session.segments\")"), rewritten)
    }

    /// A literal that is not a plain key cannot be swapped for one. Reported
    /// and failing, rather than edited approximately.
    func testAnInterpolatedCallSiteFailsRatherThanGuessing() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View {
            let name: String
            var body: some View { Text("\(sentence)") }
        }
        """)
        // A second file whose literal the lexer will not match on that line.
        try writeSource("Other.swift", """
        import SwiftUI
        struct W: View { var body: some View { Text("\(sentence)") } }
        """)

        let report = try RenameCommand(workspace: workspace(), options: .init(apply: false))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        XCTAssertEqual(report.rewrites.count, 2)
        XCTAssertEqual(report.failures, 0)
    }

    /// `--catalog-only` is for a key with no Swift call sites at all, and must
    /// not go looking for them.
    func testCatalogOnlySkipsSourceEntirely() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View { var body: some View { Text("\(sentence)") } }
        """)

        let report = try RenameCommand(
            workspace: workspace(),
            options: .init(apply: true, updateSources: false)
        ).run(from: sentence, to: "session.segments", catalogPath: nil)

        XCTAssertTrue(report.sourceEdits.isEmpty)
        XCTAssertTrue(try source("View.swift").contains(sentence), "sources were rewritten under --catalog-only")
    }

    /// The old key is gone from the catalog and the new one resolves, so a
    /// scan of the project afterwards is clean rather than newly broken.
    func testTheProjectStillResolvesAfterwards() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("各")])])
        try writeSource("View.swift", """
        import SwiftUI
        struct V: View { var body: some View { Text("\(sentence)") } }
        """)

        _ = try RenameCommand(workspace: workspace(), options: .init(apply: true))
            .run(from: sentence, to: "session.segments", catalogPath: nil)

        let scan = try ScanCommand(workspace: workspace(), options: .init()).run()
        XCTAssertTrue(scan.missingKeys.isEmpty, scan.missingKeys.map(\.value).joined(separator: ", "))
    }

    /// A key present in two catalogs is ambiguous, and renaming the wrong
    /// file's key is not something a later run can detect.
    func testAKeyInTwoCatalogsNeedsOneNamed() throws {
        let sentence = "Each session is divided into segments here"
        _ = try makeCatalog([sentence: entry(localizations: ["ja": unit("A")])])
        _ = try makeCatalog(
            [sentence: entry(localizations: ["ja": unit("B")])],
            named: "Errors.xcstrings"
        )
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings", "App/Errors.xcstrings"]
        )]

        XCTAssertThrowsError(
            try RenameCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(apply: false, updateSources: false)
            ).run(from: sentence, to: "session.segments", catalogPath: nil)
        )
    }

    // MARK: - Escaping

    /// Identifier keys need no escaping, but a key that does still has to
    /// round-trip: it is written into a Swift literal.
    func testTheNewKeyIsEscapedForSwift() {
        let command = RenameCommand(workspace: workspace(), options: .init())
        XCTAssertEqual(command.escapeForSwift("plain.key"), "plain.key")
        XCTAssertEqual(command.escapeForSwift("has \"quotes\""), #"has \"quotes\""#)
        XCTAssertEqual(command.escapeForSwift(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(command.escapeForSwift("line\nbreak"), #"line\nbreak"#)
        XCTAssertEqual(command.escapeForSwift("tab\there"), #"tab\there"#)
    }
}
