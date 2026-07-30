import XCTest
@testable import XCLocSmithKit

/// Whether `scan` finds the user-visible strings a project actually has.
///
/// Precision has an obvious failure mode — a wrong finding is right there in
/// the output. Recall fails silently: a project whose localization API this
/// tool does not model reports a clean scan and a catalog full of orphans, and
/// nothing about that output says "I could not read your code."
///
/// Every case here is an idiom from the nine-project sample that produced
/// exactly that. HSTracker was the worst: 1,041 files, 32 strings found, 350
/// live keys offered for deletion.
final class RecallTests: XCTestCase {

    // MARK: - Project-defined localization APIs

    /// `"Save".localized` — an extension on String. The literal has no
    /// enclosing call at all, so a parser that only reads call sites sees
    /// nothing.
    func testTrailingAccessorIsALocalizationAPI() {
        XCTAssertEqual(found(#"let a = "Save Deck".localized"#), ["Save Deck"])
        XCTAssertEqual(found(#"let a = "Cancel".localized(comment: "x")"#), ["Cancel"])
    }

    /// `.localized` settles the question even where the surrounding shape looks
    /// like a bypass: assigning to `.stringValue` does not localize, but the
    /// value being assigned already is localized.
    func testTrailingAccessorOutranksTheAssignmentBypass() {
        let result = analyze(#"label.stringValue = "Quit".localized"#)
        XCTAssertEqual(result.strings.map(\.value), ["Quit"])
        XCTAssertTrue(result.bypasses.isEmpty)
    }

    /// A wrapper the project defines around `NSLocalizedString`, recognised by
    /// reading its body. HSTracker's is `String.localizedString(_:comment:)`,
    /// used at 293 call sites.
    func testProjectWrappersAroundNSLocalizedStringAreFound() {
        let source = """
            extension String {
                static func localizedString(_ key: String, comment: String) -> String {
                    return NSLocalizedString(key, value: "!@#", comment: comment)
                }
            }
            func use() {
                undoManager?.setActionName(String.localizedString("Add Card", comment: ""))
            }
            """
        XCTAssertEqual(found(source), ["Add Card"])
    }

    /// The evidence has to be real. A function named `localize` that never
    /// hands its parameter to a localization API localizes nothing.
    func testAWrapperNameAloneIsNotEvidence() {
        let source = """
            func localize(_ key: String) -> String {
                return key.uppercased()
            }
            func use() { _ = localize("Add Card") }
            """
        XCTAssertEqual(found(source), [])
    }

    // MARK: - Things that are not strings to translate

    /// A dispatch queue label is an identifier. `label:` is on the
    /// likely-localizable name list, so without an exemption every queue in the
    /// project is a finding — 40 in HSTracker, 36 in GoMap.
    func testIdentifierArgumentsAreNotDisplayText() {
        XCTAssertEqual(found(#"let q = DispatchQueue(label: "net.hearthsim.readers")"#), [])
    }

    /// `@available(*, deprecated, message: "…")` is a compiler directive.
    /// DuckDuckGo has 110 of them.
    func testCompilerAttributesAreNotDisplayText() {
        XCTAssertEqual(found(#"@available(*, deprecated, message: "Use foo instead")"#), [])
    }

    /// SwiftUI's `header:` and `footer:` are `@ViewBuilder`, never strings, so
    /// a literal under those labels belongs to somebody else's type. Whisky's
    /// were `TextTableColumn(header:)` — a table printed by a command-line
    /// tool, and the whole of its reported unlocalized text.
    func testHeaderAndFooterAreNotGuessedToBeDisplayText() {
        XCTAssertEqual(found(#"let c = TextTableColumn(header: "Windows Version")"#), [])
        XCTAssertEqual(found(#"let s = SomeType(footer: "Trailing note")"#), [])
    }

    /// …but a project type that does route `header:` through
    /// `LocalizedStringKey` is still caught, by evidence rather than by name.
    func testADeclaredTypeThatLocalizesHeaderIsStillFound() {
        let source = """
            struct SectionRow: View {
                let header: String
                var body: some View { Text(LocalizedStringKey(header)) }
            }
            func use() -> some View { SectionRow(header: "Recent Activity") }
            """
        XCTAssertEqual(found(source), ["Recent Activity"])
    }

    /// Test code is never localized, and its helpers teach the classifier
    /// nothing. DuckDuckGo's `expectation(description:)` and its fixture
    /// builders were 6,140 of 29,932 findings.
    func testTestCodeIsRecognised() {
        XCTAssertTrue(source(named: "Foo.swift", text: "import XCTest\nclass T {}").isTestCode)
        XCTAssertTrue(source(named: "Foo.swift", text: "@testable import App").isTestCode)
        XCTAssertTrue(source(named: "FooTests.swift", text: "struct S {}").isTestCode)
        XCTAssertTrue(source(named: "AppTests/Helpers.swift", text: "struct S {}").isTestCode)
        XCTAssertFalse(source(named: "App/Latest.swift", text: "import SwiftUI").isTestCode)
    }

    /// A key Xcode generated from a XIB is an object identifier and a property.
    /// It cannot appear in code, so it is never an orphan — that shape was
    /// every one of HSTracker's 515 and Nimble Commander's 947.
    func testInterfaceBuilderKeysAreRecognised() {
        XCTAssertTrue(KeyHeuristics.isInterfaceBuilderKey("3aJ-8X-AqP.title"))
        XCTAssertTrue(KeyHeuristics.isInterfaceBuilderKey("BHN-1k-K8M.paletteLabel"))
        XCTAssertFalse(KeyHeuristics.isInterfaceBuilderKey("Add Card"))
        XCTAssertFalse(KeyHeuristics.isInterfaceBuilderKey("settings.display.title"))
    }

    // MARK: - Legacy .strings

    /// Migration to catalogs is partial by design. A key still living in a
    /// `.strings` file is localized — just not by anything this tool audits —
    /// and calling it missing buried DuckDuckGo's real findings under 20,323.
    func testKeysInLegacyStringsFilesAreNotMissing() {
        let keys = StringsFile.keys(in: """
            /* A comment; with a semicolon */
            "greeting" = "Hello";
            "quoted \\"value\\"" = "He said \\"hi\\";";
            bare = value;
            """)
        XCTAssertEqual(keys, ["greeting", "quoted \"value\"", "bare"])
    }

    /// Only the development language counts: a key that exists solely in a
    /// Japanese `.strings` is not evidence that the source declares it.
    func testOnlyBaseLanguageStringsCount() {
        XCTAssertTrue(StringsIndex.isBaseLanguage("Base"))
        XCTAssertTrue(StringsIndex.isBaseLanguage("en"))
        XCTAssertTrue(StringsIndex.isBaseLanguage("en-US"))
        XCTAssertFalse(StringsIndex.isBaseLanguage("ja"))
        XCTAssertFalse(StringsIndex.isBaseLanguage("de"))
    }

    // MARK: - The translate-and-verify loop

    /// A template asks for the plural forms the *target* language needs.
    ///
    /// Whoever fills it in cannot be expected to know that Russian needs four
    /// forms and Japanese one. Handing them a flat `"TODO"` and then failing
    /// the answer is a worse tool than asking for the right shape.
    func testTemplateAsksForTheTargetLanguagePluralForms() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("work.json").path

        try TranslationPayload.writeTemplate(
            keys: ["%lld items", "Save"],
            catalog: "App/Localizable.xcstrings",
            language: "ru",
            pluralKeys: ["%lld items"],
            to: path
        )
        let written = try JSONParser.parse(String(contentsOfFile: path, encoding: .utf8))
        let strings = try XCTUnwrap(written["strings"]?.objectValue)

        XCTAssertEqual(strings["Save"]?.stringValue, "TODO")
        let plural = try XCTUnwrap(strings["%lld items"]?.objectValue?["plural"]?.objectValue)
        XCTAssertEqual(Set(plural.keys), ["one", "few", "many", "other"])

        // Japanese needs one form, so it is asked for one.
        try TranslationPayload.writeTemplate(
            keys: ["%lld items"],
            catalog: "App/Localizable.xcstrings",
            language: "ja",
            pluralKeys: ["%lld items"],
            to: path
        )
        let japanese = try JSONParser.parse(String(contentsOfFile: path, encoding: .utf8))
        let categories = try XCTUnwrap(
            japanese["strings"]?.objectValue?["%lld items"]?.objectValue?["plural"]?.objectValue
        )
        XCTAssertEqual(Set(categories.keys), ["other"])
    }

    // MARK: - Helpers

    private func source(named path: String, text: String) -> AnalyzedSource {
        AnalyzedSource(path: "/tmp/\(path)", displayPath: path, text: text)
    }

    private func analyze(_ text: String) -> SourceScanResult {
        let file = source(named: "T.swift", text: text)
        return SourceAnalyzer.analyze(
            file: file,
            discovered: LocalizableDiscovery.discover(in: [file]),
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
    }

    private func found(_ text: String) -> [String] {
        analyze(text).strings.map(\.value).sorted()
    }
}
