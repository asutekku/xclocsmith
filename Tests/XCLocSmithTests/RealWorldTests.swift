import XCTest
@testable import XCLocSmithKit

/// Regressions found by running the tool against a mature multilingual project
/// (IceCubesApp: 733 keys, 19 languages, 232 plural variations, 91
/// substitutions). Every shape below is taken from that catalog.
///
/// It reported 272 format mismatches there. Two were real; the other 270 were
/// this tool misreading correct data, in four distinct ways.
final class RealWorldTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The four misreadings

    /// `%arg` is Xcode's token for a substitution's own argument, written inside
    /// that substitution's variation values. Read as `%a` (hex float) plus "rg",
    /// it turns every such plural into a bogus mismatch.
    func testArgTokenIsNotAHexFloatSpecifier() throws {
        XCTAssertTrue(FormatSpecifierScanner.specifiers(in: "%arg удзельнікаў").isEmpty)
        // A real %a is gone from the grammar; hex float has no place in UI text.
        XCTAssertTrue(FormatSpecifierScanner.specifiers(in: "50% and %a").isEmpty)

        // End to end: a substitution whose variations use %arg is correct data.
        let catalog = try makeCatalog(strings: [
            "design.tag.n-participants %lld": .object(["localizations": .object([
                "en": unit("%#@count@"),
                "be": .object([
                    "stringUnit": .object([
                        "state": .string("translated"), "value": .string("%#@count@"),
                    ]),
                    "substitutions": .object(["count": .object([
                        "argNum": .number("1"),
                        "formatSpecifier": .string("lld"),
                        "variations": .object(["plural": .object([
                            "one": unit("%arg удзельнік"),
                            "few": unit("%arg удзельнікі"),
                            "many": unit("%arg удзельнікаў"),
                            "other": unit("%arg удзельнікаў"),
                        ])]),
                    ])]),
                ]),
            ])]),
        ])
        let report = try check(catalog, languages: ["be"])
        XCTAssertEqual(report.catalogs[0].formatMismatches, [])
    }

    /// `%#@name@` consumes the argument its substitution declares. Counting only
    /// plain specifiers makes every substitution-based translation look like it
    /// dropped all of them.
    func testSubstitutionReferenceConsumesItsArgument() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: "%lld followers",
            translation: "%#@followers@",
            substitutions: ["followers": "lld"]
        ))
    }

    /// An argument can be consumed inside a substitution's variation values
    /// ("%2$@ follower"), where a top-level count cannot see it.
    func testSubstitutionsSuppressTheCountComparison() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: "%lld %@",
            translation: "%#@followers@",
            substitutions: ["followers": "lld"]
        ))
    }

    /// A plural category is compared against the same category in the source
    /// language. English "1 new post" is German "Ein neuer Beitrag": the
    /// singular spells the number out and carries no specifier, correctly.
    func testPluralCategoriesAreComparedAgainstTheirCounterpart() throws {
        let catalog = try makeCatalog(strings: [
            "timeline-new-posts %lld": .object(["localizations": .object([
                "en": plural(["one": "1 new post", "other": "%lld new posts"]),
                "de": plural(["one": "Ein neuer Beitrag", "other": "%lld neue Beiträge"]),
            ])]),
        ])
        let report = try check(catalog)
        XCTAssertEqual(report.catalogs[0].formatMismatches, [])
    }

    /// Many projects use identifier keys: "notifications.label.favorite %lld"
    /// whose English value is "starred". Comparing a translation against the key
    /// compares it against something no user ever sees.
    func testIdentifierKeysAreComparedAgainstTheSourceValue() throws {
        let catalog = try makeCatalog(strings: [
            "notifications.label.favorite %lld": .object(["localizations": .object([
                "en": unit("starred"),
                "be": unit("пазначана"),
            ])]),
        ])
        let report = try check(catalog)
        XCTAssertEqual(report.catalogs[0].formatMismatches, [])
    }

    // MARK: - What must still be caught

    /// The two real defects in that project: a translator dropped the `@` from
    /// `%@`, and another dropped the placeholder entirely.
    func testGenuineSpecifierDefectsAreStillReported() throws {
        let catalog = try makeCatalog(strings: [
            "instance.list.posts-%@": .object(["localizations": .object([
                "en": unit("%@ posts"),
                "ca": unit("% publicacions"),
            ])]),
            "%@ already-exists": .object(["localizations": .object([
                "en": unit("%@ already exists"),
                "pl": unit("już istnieje"),
            ])]),
        ])
        let report = try check(catalog)
        let languages = Set(report.catalogs[0].formatMismatches.map(\.language))
        XCTAssertEqual(languages, ["ca", "pl"])
    }

    /// Slavic plurals need `few` and `many`; a catalog carrying only one/other
    /// is genuinely incomplete for be, uk and pl.
    func testSlavicPluralGapsAreReported() throws {
        let catalog = try makeCatalog(strings: [
            "status.poll.n-votes %lld": .object(["localizations": .object([
                "en": plural(["one": "1 vote", "other": "%lld votes"]),
                "be": plural(["one": "%lld голас", "other": "%lld галасоў"]),
            ])]),
        ])
        let report = try check(catalog, languages: ["be"])
        let gap = report.catalogs[0].pluralGaps.first
        XCTAssertEqual(gap?.language, "be")
        XCTAssertEqual(gap?.missingCategories, ["few", "many"])
    }

    /// An interpolated literal is reported as the key Xcode would extract, not
    /// as the fragments around the holes: `"\(a) ⸱ \(b)"` names nothing.
    func testInterpolatedLiteralsReportTheExtractedKey() {
        let file = AnalyzedSource(
            path: "/tmp/T.swift",
            displayPath: "T.swift",
            text: #"Text("\(name) ⸱ \(handle)")"#
        )
        let result = SourceAnalyzer.analyze(
            file: file,
            discovered: DiscoveredLocalizables(),
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
        XCTAssertEqual(result.strings.map(\.value), ["%@ ⸱ %@"])
    }

    /// A literal percent is written `%%` by Xcode's extractor.
    func testLiteralPercentIsDoubledInTheExtractedKey() {
        let file = AnalyzedSource(
            path: "/tmp/T.swift",
            displayPath: "T.swift",
            text: #"Text("Battery at \(pct)%")"#
        )
        let result = SourceAnalyzer.analyze(
            file: file,
            discovered: DiscoveredLocalizables(),
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
        XCTAssertEqual(result.strings.map(\.value), ["Battery at %@%%"])

        let pattern = try? XCTUnwrap(file.lexed.literals.first?.formatPattern)
        let regex = try? NSRegularExpression(pattern: "^" + (pattern ?? "") + "$")
        let extracted = "Battery at %lld%%"
        let range = NSRange(extracted.startIndex..., in: extracted)
        XCTAssertNotNil(regex?.firstMatch(in: extracted, range: range))
    }

    // MARK: - Helpers

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }

    private func plural(_ forms: [String: String]) -> JSONValue {
        var categories: [String: JSONValue] = [:]
        for (category, value) in forms { categories[category] = unit(value) }
        return .object(["variations": .object(["plural": .object(categories)])])
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

    private func check(_ catalog: URL, languages: [String] = []) throws -> CheckReport {
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])]
        configuration.languages = languages
        let command = CheckCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(languages: languages)
        )
        return try command.run()
    }
}
