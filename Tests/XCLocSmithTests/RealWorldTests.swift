import XCTest
@testable import XCLocSmithKit

/// Regressions found by running the tool against mature multilingual projects:
/// IceCubesApp (733 keys, 19 languages, 232 plurals, 91 substitutions), then
/// Mastodon for iOS (52 languages, 9 catalogs), Whisky, Loop and damus.
///
/// Every shape below is taken from one of those catalogs. IceCubesApp alone
/// produced 272 format mismatches; two were real and the other 270 were this
/// tool misreading correct data, in four distinct ways.
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
    /// as the fragments around the holes: `"Posts by \(a) ⸱ \(b)"` must not be
    /// reported as `"Posts by  ⸱ "`, which names nothing searchable.
    func testInterpolatedLiteralsReportTheExtractedKey() {
        XCTAssertEqual(analyzed(#"Text("Posts by \(name) ⸱ \(handle)")"#), ["Posts by %@ ⸱ %@"])
    }

    /// `Text("\(name)")` extracts to the key "%@", which holds nothing a
    /// translator could act on — the same verdict `check` reaches about a
    /// catalog key of "%@". Judging the raw literal instead sees the word
    /// `name` and demands a catalog entry for pure interpolation; Mastodon's
    /// timeline views alone produced eight of those.
    func testPureInterpolationIsNotDemandedOfACatalog() {
        XCTAssertEqual(analyzed(#"Text("\(name)")"#), [])
        XCTAssertEqual(analyzed(#"Text("@\(handle)")"#), [])
        XCTAssertEqual(analyzed(##"Text(" · @\(handle)")"##), [])
        // A word among the holes still has to be localized.
        XCTAssertEqual(analyzed(#"Text("(content: \(body))")"#), ["(content: %@)"])
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

    // MARK: - Found on Mastodon, Whisky, Loop and damus

    /// Near-duplicates are a question about the *strings*, not the keys. A
    /// project that keys by identifier puts siblings in a namespace on purpose:
    /// comparing keys reported 554 pairs on Mastodon, every one of them a pair
    /// of deliberately distinct strings that merely share a prefix.
    func testSimilarityComparesSourceTextNotIdentifierKeys() throws {
        let catalog = try makeCatalog(strings: [
            "Scene.Collections.remove": .object(["localizations": .object(["en": unit("Remove")])]),
            "Scene.Collections.removeMe": .object(["localizations": .object(["en": unit("Leave collection")])]),
            "Scene.Profile.editProfile": .object(["localizations": .object(["en": unit("Edit profile")])]),
            "Scene.Settings.editProfile2": .object(["localizations": .object(["en": unit("Edit Profile")])]),
        ])
        let pairs = try check(catalog).catalogs[0].similarKeys
        // The two near-identical *keys* are not a finding; the two near-identical
        // English strings are, and the report names the text it compared.
        XCTAssertEqual(pairs.map { [$0.a, $0.b] }, [["Scene.Profile.editProfile", "Scene.Settings.editProfile2"]])
        XCTAssertEqual(pairs.first?.aText, "Edit profile")
        XCTAssertEqual(pairs.first?.bText, "Edit Profile")
    }

    /// A pluralised key carries its text in the `other` variation, not in a
    /// flat value. `plural.count.vote` and `plural.count.voter` render "%lld
    /// votes" and "%lld voters" — comparing the keys instead reports a
    /// near-duplicate that does not exist.
    func testPluralKeysAreComparedByTheTextTheyRender() throws {
        let catalog = try makeCatalog(strings: [
            "plural.count.vote": .object(["localizations": .object([
                "en": plural(["one": "1 vote", "other": "%lld votes"]),
            ])]),
            "plural.count.voter": .object(["localizations": .object([
                "en": plural(["one": "1 voter", "other": "%lld voters"]),
            ])]),
        ])
        XCTAssertEqual(try check(catalog).catalogs[0].similarKeys, [])
    }

    /// IceCubesApp's platform picker has device variations for iphone, ipad,
    /// mac and applevision but no `other` — in every one of its 19 languages,
    /// English included. That is one missing case in the source string, and
    /// reporting it once per language sends 18 translators after it.
    func testGapsTheSourceSharesAreReportedOnceAgainstTheSource() throws {
        func devices(_ names: [String]) -> JSONValue {
            var cases: [String: JSONValue] = [:]
            for name in names { cases[name] = unit(name) }
            return .object(["variations": .object(["device": .object(cases)])])
        }
        let catalog = try makeCatalog(strings: [
            "settings.display.section.platform": .object(["localizations": .object([
                "en": devices(["iphone", "ipad", "mac"]),
                "de": devices(["iphone", "ipad", "mac"]),
                "ja": devices(["iphone", "ipad"]),
            ])]),
        ])
        let gaps = try check(catalog, languages: ["en", "de", "ja"]).catalogs[0].pluralGaps
        XCTAssertEqual(gaps.map(\.language), ["en"])
        XCTAssertEqual(gaps.first?.missingCategories, ["device.other"])

        // …including when the source language is not in the checked set at all,
        // which is the usual case — dropping it there would lose it silently.
        let translationsOnly = try check(catalog, languages: ["de", "ja"]).catalogs[0].pluralGaps
        XCTAssertEqual(translationsOnly.map(\.language), ["en"])
    }

    /// An exported `.xcloc` carries a copy of every catalog under "Source
    /// Contents". damus keeps one in the repo and localizes through `.strings`,
    /// so discovery invented three targets pointed at an export artifact — and
    /// `prune` would have offered to edit it.
    func testExportedLocalizationCatalogsAreNotProjectCatalogs() throws {
        let export = root.appendingPathComponent("App/en-US.xcloc/Source Contents/App")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try "{}".write(to: export.appendingPathComponent("Localizable.xcstrings"), atomically: true, encoding: .utf8)
        try "import SwiftUI".write(to: export.appendingPathComponent("V.swift"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ProjectDiscovery.discoverCatalogs(root: root.path, excluded: []), [])
        XCTAssertThrowsError(try ProjectDiscovery.discoverTargets(root: root.path, excluded: []))
    }

    /// Two catalog directories under one top-level folder must not both be
    /// named after it: duplicate target names make the config ambiguous.
    func testDiscoveredTargetNamesAreUnique() throws {
        for directory in ["App/Resources", "App/Extension"] {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "{}".write(to: url.appendingPathComponent("Localizable.xcstrings"), atomically: true, encoding: .utf8)
        }
        let names = try ProjectDiscovery.discoverTargets(root: root.path, excluded: []).map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(Set(names).count, 2)
    }

    /// `PEError(message: "Invalid PE file")` is an error payload, not a display
    /// string. The project declares `PEError` and nothing in that declaration
    /// routes `message` through `LocalizedStringKey`, so the built-in list of
    /// likely-localizable parameter names must not override that evidence.
    func testDeclaredTypesOverrideTheParameterNameHeuristic() {
        let source = """
            public struct PEError: Error {
                let message: String
                static let invalidPEFile = PEError(message: "Invalid PE file")
            }
            """
        let file = AnalyzedSource(path: "/tmp/T.swift", displayPath: "T.swift", text: source)
        let discovered = LocalizableDiscovery.discover(in: [file])
        XCTAssertTrue(discovered.declaredTypes.contains("PEError"))

        let result = SourceAnalyzer.analyze(
            file: file,
            discovered: discovered,
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
        XCTAssertEqual(result.strings.map(\.value), [])
    }

    /// One string cannot serve four grammatical numbers. A flat Russian
    /// translation of a pluralised key is incomplete, however filled-in the
    /// coverage percentage looks — this is what a model writes when handed a
    /// bare `"TODO"`, and the check that makes the loop safe to automate.
    func testFlatTranslationOfAPluralisedKeyIsIncomplete() throws {
        let catalog = try makeCatalog(strings: [
            "%lld items": .object(["localizations": .object([
                "en": plural(["one": "1 item", "other": "%lld items"]),
                "ru": unit("%lld предметов"),
                "ja": unit("%lld個"),
            ])]),
        ])
        let gaps = try check(catalog, languages: ["ru", "ja"]).catalogs[0].pluralGaps
        XCTAssertEqual(gaps.map(\.language), ["ru"])
        XCTAssertEqual(gaps.first?.missingCategories, ["one", "few", "many", "other"])
        // Japanese requires `other` alone, so a flat string is exactly
        // equivalent and must not be reported.
    }

    /// Format specifiers are compared *inside* plural variations.
    ///
    /// They were not, for the whole of this tool's life before this test: the
    /// walk that collects comparable values descended into the `stringUnit`
    /// object instead of stopping at the category that holds it, so nothing
    /// under `variations` was ever collected. A German `other` form that had
    /// dropped its `%lld` reported clean — and plurals are precisely where the
    /// counts live.
    ///
    /// GoMap ships this in Arabic: `one` and `other` hold the translator's
    /// description of the string rather than the string, so the count is gone.
    func testFormatSpecifiersAreCheckedInsidePluralVariations() throws {
        let catalog = try makeCatalog(strings: [
            "%lld posts": .object(["localizations": .object([
                "en": plural(["one": "1 post", "other": "%lld posts"]),
                "de": plural(["one": "1 Beitrag", "other": "Beiträge"]),
            ])]),
        ])
        let mismatches = try check(catalog, languages: ["de"]).catalogs[0].formatMismatches
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(mismatches.first?.language, "de")
        XCTAssertTrue(mismatches.first?.problem.contains("plural.other") == true)
        XCTAssertEqual(mismatches.first?.translation, "Beiträge")
    }

    /// …but a category standing for one known count may spell the number out.
    ///
    /// English "%lld new post" is German "ein neuer Beitrag" and Arabic
    /// "بقي تكرار واحد". Comparing those was 60 of the first 62 findings the
    /// fix above produced, which would have made the whole check unusable.
    func testExactCountCategoriesMaySpellTheNumberOut() throws {
        let catalog = try makeCatalog(strings: [
            "timeline-new-posts %lld": .object(["localizations": .object([
                "en": plural(["one": "%lld new post", "other": "%lld new posts"]),
                "de": plural(["one": "ein neuer Beitrag", "other": "%lld neue Beiträge"]),
            ])]),
        ])
        XCTAssertEqual(try check(catalog, languages: ["de"]).catalogs[0].formatMismatches, [])
        XCTAssertTrue(PluralRules.isExactCount(category: "plural.one"))
        XCTAssertTrue(PluralRules.isExactCount(category: "plural.two"))
        XCTAssertFalse(PluralRules.isExactCount(category: "plural.other"))
        XCTAssertFalse(PluralRules.isExactCount(category: "plural.many"))
        XCTAssertFalse(PluralRules.isExactCount(category: ""))
    }

    /// A template carries the source string, because a key is not always one.
    ///
    /// Mastodon keys by identifier: `notifications.label.favorite %lld` renders
    /// as "starred". Handing that key to a translator — or a model — with no
    /// English beside it asks for a translation of a string they cannot see.
    func testTemplateCarriesTheSourceStringAndComment() throws {
        let catalog = try makeCatalog(strings: [
            "notifications.label.favorite": .object([
                "comment": .string("Tab label under the icon"),
                "localizations": .object(["en": unit("starred"), "ru": .object([:])]),
            ]),
            "Save": .object(["localizations": .object(["en": unit("Save"), "ru": .object([:])])]),
        ])
        let output = root.appendingPathComponent("work.json")
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])]
        _ = try CheckCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(languages: ["ru"], templatePath: output.path)
        ).run()

        let payload = try JSONParser.parse(String(contentsOfFile: output.path, encoding: .utf8))
        let strings = try XCTUnwrap(payload["strings"]?.objectValue)
        let entry = try XCTUnwrap(strings["notifications.label.favorite"]?.objectValue)
        XCTAssertEqual(entry["source"]?.stringValue, "starred")
        XCTAssertEqual(entry["comment"]?.stringValue, "Tab label under the icon")
        XCTAssertEqual(entry["value"]?.stringValue, "TODO")
        // A key that is its own English string stays in the short form.
        XCTAssertEqual(strings["Save"]?.stringValue, "TODO")
    }

    // MARK: - Helpers

    /// The catalog keys `scan` would demand for a fragment of Swift.
    private func analyzed(_ source: String) -> [String] {
        let file = AnalyzedSource(path: "/tmp/T.swift", displayPath: "T.swift", text: source)
        return SourceAnalyzer.analyze(
            file: file,
            discovered: DiscoveredLocalizables(),
            options: Configuration(root: "/tmp").classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        ).strings.map(\.value)
    }

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
