import XCTest
@testable import XCLocSmithKit

final class CatalogTests: XCTestCase {

    // MARK: - Non-destructive writes

    /// A localization can hold a `stringUnit` *and* `substitutions`. Replacing
    /// the object wholesale deletes plural arguments a translator authored in
    /// Xcode, and nothing in the file records that they ever existed.
    func testWritingRefusesToDestroySubstitutions() throws {
        var catalog = try makeCatalog(strings: [
            "Found %#@count@": .object(["localizations": .object(["ja": .object([
                "stringUnit": .object(["state": .string("translated"), "value": .string("%#@count@")]),
                "substitutions": .object(["count": .object([
                    "argNum": .number("1"),
                    "formatSpecifier": .string("lld"),
                ])]),
            ])])])
        ])

        XCTAssertThrowsError(
            try catalog.setTranslation(key: "Found %#@count@", language: "ja", value: "flat", state: .translated)
        ) { error in
            guard case SmithError.wouldDiscardStructure(_, _, let structure) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(structure.contains("substitutions"))
        }
        XCTAssertNotNil(catalog.substitutions("Found %#@count@", "ja")["count"])
    }

    func testFlattenIsOptIn() throws {
        var catalog = try makeCatalog(strings: [
            "K": .object(["localizations": .object(["ja": .object([
                "variations": .object(["plural": .object([
                    "other": .object(["stringUnit": .object([
                        "state": .string("translated"), "value": .string("x"),
                    ])]),
                ])]),
            ])])])
        ])
        try catalog.setTranslation(key: "K", language: "ja", value: "flat", state: .translated, flatten: true)
        XCTAssertEqual(catalog.value("K", "ja"), "flat")
        XCTAssertNil(catalog.localization("K", "ja")?["variations"])
    }

    /// Unknown sibling fields inside a localization must survive an edit.
    func testWritingPreservesUnknownSiblings() throws {
        var catalog = try makeCatalog(strings: [
            "K": .object(["localizations": .object(["ja": .object([
                "stringUnit": .object(["state": .string("new"), "value": .string("old")]),
                "futureField": .string("keep me"),
            ])])])
        ])
        try catalog.setTranslation(key: "K", language: "ja", value: "new value", state: .translated)
        XCTAssertEqual(catalog.localization("K", "ja")?["futureField"]?.stringValue, "keep me")
        XCTAssertEqual(catalog.value("K", "ja"), "new value")
    }

    func testAuthoringPlurals() throws {
        var catalog = try makeCatalog(strings: ["%lld items": .object([:])])
        try catalog.setPluralTranslation(key: "%lld items", language: "ru", category: "one", value: "%lld штука", state: .translated)
        try catalog.setPluralTranslation(key: "%lld items", language: "ru", category: "few", value: "%lld штуки", state: .translated)
        let status = catalog.status("%lld items", "ru")
        guard case .variations(let missing) = status else { return XCTFail("expected variations") }
        XCTAssertEqual(missing, ["many", "other"])
    }

    // MARK: - Status semantics

    /// Xcode shows a `new` unit as work still to do; counting it as translated
    /// inflates coverage and hides real work.
    func testNewStateIsNotTranslated() throws {
        let catalog = try makeCatalog(strings: [
            "K": .object(["localizations": .object(["ja": .object([
                "stringUnit": .object(["state": .string("new"), "value": .string("draft")]),
            ])])])
        ])
        XCTAssertFalse(catalog.status("K", "ja").isComplete)
    }

    func testEmptyValueIsNotTranslated() throws {
        let catalog = try makeCatalog(strings: [
            "K": .object(["localizations": .object(["ja": .object([
                "stringUnit": .object(["state": .string("translated"), "value": .string("")]),
            ])])])
        ])
        XCTAssertEqual(catalog.status("K", "ja"), .empty)
    }

    /// The category set is per language: filling `one` completes Japanese and
    /// leaves Russian three rows short.
    func testPluralCompletenessIsPerLanguage() throws {
        func catalog(language: String, categories: [String]) throws -> Catalog {
            var plural: [String: JSONValue] = [:]
            for category in categories {
                plural[category] = .object(["stringUnit": .object([
                    "state": .string("translated"), "value": .string("v"),
                ])])
            }
            return try makeCatalog(strings: [
                "%lld": .object(["localizations": .object([language: .object([
                    "variations": .object(["plural": .object(plural)]),
                ])])])
            ])
        }

        XCTAssertTrue(try catalog(language: "ja", categories: ["other"]).status("%lld", "ja").isComplete)
        XCTAssertFalse(try catalog(language: "en", categories: ["other"]).status("%lld", "en").isComplete)
        XCTAssertTrue(try catalog(language: "en", categories: ["one", "other"]).status("%lld", "en").isComplete)
        XCTAssertFalse(try catalog(language: "ru", categories: ["one", "other"]).status("%lld", "ru").isComplete)
        XCTAssertTrue(try catalog(language: "ru", categories: ["one", "few", "many", "other"]).status("%lld", "ru").isComplete)
    }

    // MARK: - Kinds

    func testCatalogKindFromFileName() {
        XCTAssertEqual(CatalogKind(fileName: "Localizable.xcstrings"), .localizable)
        XCTAssertEqual(CatalogKind(fileName: "Errors.xcstrings"), .table("Errors"))
        XCTAssertEqual(CatalogKind(fileName: "InfoPlist.xcstrings"), .infoPlist)
        XCTAssertEqual(CatalogKind(fileName: "AppShortcuts.xcstrings"), .appShortcuts)
    }

    /// Info.plist keys and Siri phrases never appear in source, so treating them
    /// as code-referenced would offer to delete an app's camera permission text.
    func testSpecialCatalogsAreNotSourceReferenced() {
        XCTAssertFalse(CatalogKind.infoPlist.isReferencedFromSource)
        XCTAssertFalse(CatalogKind.appShortcuts.isReferencedFromSource)
        XCTAssertTrue(CatalogKind.localizable.isReferencedFromSource)
        XCTAssertTrue(CatalogKind.table("Errors").isReferencedFromSource)
        // App Shortcut phrases are meant to be near-duplicates of one another.
        XCTAssertFalse(CatalogKind.appShortcuts.wantsSimilarKeyCheck)
    }

    // MARK: - Symlinks

    /// Writing through a symlink must update the file it points at, not replace
    /// the link with a regular file and orphan the real catalog.
    func testWritingFollowsSymlinks() throws {
        let directory = try temporaryDirectory()
        let real = directory.appendingPathComponent("Real.xcstrings")
        let link = directory.appendingPathComponent("Link.xcstrings")
        try #"{"sourceLanguage":"en","strings":{"K":{}},"version":"1.0"}"#
            .write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        var catalog = try Catalog(path: link.path)
        try catalog.setTranslation(key: "K", language: "ja", value: "v", state: .translated)
        try catalog.save()

        let reloaded = try Catalog(path: real.path)
        XCTAssertEqual(reloaded.value("K", "ja"), "v")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    // MARK: - Format specifiers

    func testFormatSpecifierMismatch() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: "%lld items", translation: "%lld 個"))
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(source: "%lld items", translation: "%@ 個"))
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(source: "%lld items", translation: "no specifier"))
        // Positional reordering is exactly what %1$@ exists for.
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: "%@ by %@", translation: "%2$@ の %1$@"))
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(source: "%@ by %@", translation: "%3$@"))
        // %% is a literal percent, not an argument.
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: "100%% done", translation: "100%% 完了"))
    }

    /// Prose with a literal percent must not be read as a format specifier:
    /// "100% private" would otherwise parse as `% p`, and "50% of" as `% o`.
    func testLiteralPercentInProseIsNotASpecifier() {
        for prose in [
            "100% private — your data never leaves your device",
            "Zones start at 50–60% of max HR",
            "Battery at 80% and charging",
        ] {
            XCTAssertTrue(
                FormatSpecifierScanner.specifiers(in: prose).isEmpty,
                "false specifier in: \(prose)"
            )
            XCTAssertNil(FormatSpecifierScanner.mismatch(source: prose, translation: "翻訳"))
        }
        // A real specifier alongside prose percentages is still found.
        let mixed = "Zones based on % of max HR (%lld bpm)"
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: mixed).map(\.raw), ["%lld"])
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeCatalog(strings: [String: JSONValue]) throws -> Catalog {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("Localizable.xcstrings").path
        let document = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        try JSONWriter.text(document).write(toFile: path, atomically: true, encoding: .utf8)
        return try Catalog(path: path)
    }
}
