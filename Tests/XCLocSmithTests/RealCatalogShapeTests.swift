import XCTest
@testable import XCLocSmithKit

/// Structural shapes mined from nine real open-source catalogs (Whisky, Loop,
/// NetNewsWire, IceCubesApp, Mastodon for iOS, HSTracker, Nimble Commander,
/// GoMap, DuckDuckGo's apple-browsers, plus damus), reduced to the smallest
/// fixture that still exercises the case. Each test names the project the
/// shape came from.
///
/// Shapes hunted for and NOT found anywhere in that corpus, recorded here so
/// nobody re-hunts them: device variations nested inside plural variations (or
/// vice versa), any variation kind besides `plural`/`device` (no `width`),
/// `^[...](inflect: true)` grammar agreement, Unicode directional marks
/// (U+200E/200F/061C) in values, and `stringUnit.state` values beyond
/// `new` / `needs_review` / `translated`.
final class RealCatalogShapeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - extractionState: automatic  (DuckDuckGo apple-browsers)

    /// DuckDuckGo's `NetPAppStoreInfoPlist.xcstrings` marks `CFBundleDisplayName`
    /// with `extractionState: "automatic"` — a value Xcode writes that the WWDC
    /// material never names. It means "maintained by the build": not stale, not
    /// symbol-eligible, and the key still takes part in coverage.
    func testAutomaticExtractionStateIsModeled() throws {
        let catalog = try makeCatalog(strings: [
            "CFBundleDisplayName": .object([
                "extractionState": .string("automatic"),
                "shouldTranslate": .bool(false),
            ]),
            "Managed key": .object([
                "extractionState": .string("automatic"),
                "localizations": .object(["en": unit("Managed key")]),
            ]),
        ])
        let loaded = try Catalog(path: catalog.path)
        XCTAssertEqual(loaded.extractionState("CFBundleDisplayName"), .automatic)
        XCTAssertFalse(ExtractionState.automatic.isSymbolEligible)

        let report = try check(catalog, languages: ["ja"]).catalogs[0]
        // Not retired: an automatic key is live work, unlike a stale one.
        XCTAssertEqual(report.staleKeys, [])
        XCTAssertEqual(report.doNotTranslateKeys, ["CFBundleDisplayName"])
        XCTAssertEqual(report.coverage.first { $0.language == "ja" }?.missing, ["Managed key"])
    }

    // MARK: - Substitution specifiers with precision  (GoMap)

    /// GoMap's `%.1f meters, %ld nodes` declares `formatSpecifier: ".1f"` — the
    /// precision lives *inside* the declared specifier. Expansion must yield a
    /// parseable `%.1f`, and the whole shape must check clean.
    func testSubstitutionSpecifierMayCarryPrecision() throws {
        let expanded = FormatSpecifierScanner.expanding(
            "%#@meters@, %#@nodes@",
            with: ["meters": ".1f", "nodes": "ld"]
        )
        XCTAssertEqual(expanded, "%.1f, %ld")
        XCTAssertEqual(
            FormatSpecifierScanner.specifiers(in: expanded).map(\.conversionClass),
            ["float", "integer"]
        )

        let catalog = try makeCatalog(strings: [
            "%.1f meters, %ld nodes": .object(["localizations": .object([
                "en": substitutionLocalization(
                    value: "%#@meters@, %#@nodes@",
                    substitutions: [
                        "meters": (argNum: 1, specifier: ".1f", plurals: ["other": "%arg meters"]),
                        "nodes": (argNum: 2, specifier: "ld", plurals: ["one": "%arg node", "other": "%arg nodes"]),
                    ]
                ),
                "de": substitutionLocalization(
                    value: "%#@meters@, %#@nodes@",
                    substitutions: [
                        "meters": (argNum: 1, specifier: ".1f", plurals: ["other": "%arg Meter"]),
                        "nodes": (argNum: 2, specifier: "ld", plurals: ["one": "%arg Knoten", "other": "%arg Knoten"]),
                    ]
                ),
            ])]),
        ])
        XCTAssertEqual(try check(catalog, languages: ["de"]).catalogs[0].formatMismatches, [])
    }

    /// IceCubesApp's `account.label.followers %lld %@` declares its substitution
    /// with no `argNum` at all in several languages. That is a real, working
    /// catalog: the declaration must still expand, and nothing may report it.
    func testSubstitutionWithoutArgNumIsAccepted() throws {
        let followers: [String: JSONValue] = [
            "formatSpecifier": .string("lld"),   // deliberately no argNum
            "variations": .object(["plural": .object([
                "one": unit("%arg падпісчык"),
                "few": unit("%arg падпісчыкі"),
                "many": unit("%arg падпісчыкаў"),
                "other": unit("%arg падпісчыка"),
            ])]),
        ]
        let catalog = try makeCatalog(strings: [
            "account.label.followers %lld %@": .object(["localizations": .object([
                "en": unit("%lld followers of %@"),
                "be": .object([
                    "stringUnit": .object(["state": .string("translated"), "value": .string("%#@followers@ %@")]),
                    "substitutions": .object(["followers": .object(followers)]),
                ]),
            ])]),
        ])
        let loaded = try Catalog(path: catalog.path)
        XCTAssertEqual(
            loaded.substitutionSpecifiers("account.label.followers %lld %@", "be"),
            ["followers": "lld"]
        )
        XCTAssertEqual(loaded.substitutionProblems("account.label.followers %lld %@", "be"), [])
        XCTAssertEqual(try check(catalog, languages: ["be"]).catalogs[0].formatMismatches, [])
    }

    /// IceCubesApp's `design.tag.n-posts-from-n-participants %lld %lld`: one
    /// value referencing two distinct substitutions. Both references must be
    /// seen, and an undeclared one must be named precisely.
    func testMultipleSubstitutionReferencesInOneValue() throws {
        let value = "%#@count_posts@ posts from %#@count_participants@ participants"
        XCTAssertEqual(
            FormatSpecifierScanner.substitutionReferences(in: value),
            ["count_posts", "count_participants"]
        )

        func localization(declaring names: [String]) -> JSONValue {
            var substitutions: [String: JSONValue] = [:]
            for (index, name) in names.enumerated() {
                substitutions[name] = .object([
                    "argNum": .number("\(index + 1)"),
                    "formatSpecifier": .string("lld"),
                    "variations": .object(["plural": .object(["other": unit("%arg")])]),
                ])
            }
            return .object([
                "stringUnit": .object(["state": .string("translated"), "value": .string(value)]),
                "substitutions": .object(substitutions),
            ])
        }

        let complete = try makeCatalog(strings: [
            "design.tag.n-posts-from-n-participants %lld %lld": .object(["localizations": .object([
                "en": localization(declaring: ["count_posts", "count_participants"]),
            ])]),
        ])
        let loaded = try Catalog(path: complete.path)
        XCTAssertEqual(
            loaded.substitutionProblems("design.tag.n-posts-from-n-participants %lld %lld", "en"),
            []
        )

        let broken = try makeCatalog(named: "Broken.xcstrings", strings: [
            "design.tag.n-posts-from-n-participants %lld %lld": .object(["localizations": .object([
                "en": localization(declaring: ["count_posts"]),
            ])]),
        ])
        let problems = try Catalog(path: broken.path)
            .substitutionProblems("design.tag.n-posts-from-n-participants %lld %lld", "en")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("count_participants"), "\(problems)")
    }

    // MARK: - Degenerate entries  (GoMap, IceCubesApp, damus)

    /// A localization that is an empty object — `"ru": {}` — appears in real
    /// catalogs (seen in a Mastodon-style catalog). It holds no translation and
    /// must count as missing, not as done and not as a crash.
    func testEmptyLocalizationObjectCountsAsMissing() throws {
        let catalog = try makeCatalog(strings: [
            "notifications.label.favorite %lld": .object(["localizations": .object([
                "en": unit("starred"),
                "ru": .object([:]),
            ])]),
        ])
        let loaded = try Catalog(path: catalog.path)
        XCTAssertEqual(loaded.status("notifications.label.favorite %lld", "ru"), .missing)
        let coverage = try check(catalog, languages: ["ru"]).catalogs[0].coverage
        XCTAssertEqual(coverage.first { $0.language == "ru" }?.missing, ["notifications.label.favorite %lld"])
    }

    /// GoMap ships a key that is the empty string whose whole entry is `{}`;
    /// IceCubesApp's empty key carries 13 localizations, all `""`. Both load,
    /// and the empty key is classed untranslatable rather than demanded of
    /// translators.
    func testEmptyStringKeyIsUntranslatableNotFatal() throws {
        let catalog = try makeCatalog(strings: [
            "": .object([:]),
            "Real key": .object(["localizations": .object(["en": unit("Real key")])]),
        ])
        let report = try check(catalog, languages: ["ja"]).catalogs[0]
        XCTAssertTrue(report.untranslatableKeys.contains(""))
        XCTAssertEqual(report.translatableCount, 1)
        XCTAssertEqual(report.keyCount, 2)
    }

    // MARK: - Awkward key text  (Loop, GoMap, NetNewsWire, IceCubesApp)

    /// Real keys contain embedded newlines (Loop), leading tabs with trailing
    /// spaces (GoMap's "\tRelation "), and emoji (NetNewsWire's "🦖 Dinosaurs").
    /// All are ordinary translatable keys and must survive a byte-exact
    /// round-trip through the writer.
    func testNewlineTabAndEmojiKeysAreOrdinaryKeys() throws {
        let loopKey = "%@ places windows slightly above the absolute center,\nwhich can be found more ergonomic."
        let keys = [loopKey, "\tRelation ", "🦖 Dinosaurs"]
        var strings: [String: JSONValue] = [:]
        for key in keys {
            strings[key] = .object(["localizations": .object(["en": unit(key)])])
        }
        let catalog = try makeCatalog(strings: strings)
        let report = try check(catalog, languages: ["ja"]).catalogs[0]
        XCTAssertEqual(report.translatableCount, 3)
        XCTAssertEqual(report.untranslatableKeys, [])

        // Round-trip: serialize, reparse, same keys and values.
        let loaded = try Catalog(path: catalog.path)
        let reparsed = try JSONParser.parse(loaded.serialized())
        let reloadedKeys = Set((reparsed["strings"]?.objectValue ?? [:]).keys)
        XCTAssertEqual(reloadedKeys, Set(keys))
    }

    /// IceCubesApp's longest key is a 704-character Markdown bullet list of
    /// package credits. Long keys are legitimate — the key *is* the English —
    /// and must stay translatable without tripping the similarity machinery.
    func testVeryLongMarkdownKeyIsHandled() throws {
        let longKey = (0..<12)
            .map { "• [Package\($0)](https://github.com/example/package\($0))" }
            .joined(separator: "\n\n")
        XCTAssertGreaterThan(longKey.count, 500)
        XCTAssertTrue(KeyHeuristics.isTranslatable(longKey))

        let pairs = SimilarKeys.similar(
            entries: [(longKey, longKey), ("Add Account", "Add Account")],
            threshold: 85,
            ignored: []
        )
        XCTAssertEqual(pairs, [], "a long key must not pair with unrelated short strings")
    }

    // MARK: - RTL translations with specifiers  (Whisky, Loop, GoMap)

    /// Arabic values keep their format specifiers while the surrounding text
    /// runs right-to-left — Whisky's "Remove %@؟", Loop's "%@ يضع النوافذ…",
    /// GoMap's " (%d الأعضاء)\n". None of these is a mismatch.
    func testRTLValuesWithSpecifiersCompareClean() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: "Remove %@?",
            translation: "Remove %@؟"
        ))
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: "%@ places windows slightly above the absolute center,\nwhich can be found more ergonomic.",
            translation: "%@ يضع النوافذ قليلاً فوق المركز المطلق، مما يمكن أن يكون أكثر ملاءمة من الناحية العملية."
        ))
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: " (%d members)\n",
            translation: " (%d الأعضاء)\n"
        ))
        // Dropping the specifier in an RTL value is still caught.
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(
            source: "Remove %@?",
            translation: "إزالة؟"
        ))
    }

    // MARK: - High positional indices  (Loop, DuckDuckGo)

    /// Loop reorders three arguments; DuckDuckGo goes up to `%10$@`. A
    /// positional translation may reference any argument the source has, in
    /// any order — and one past the end is an error, not an argument.
    func testHighPositionalIndicesResolveAgainstTheSource() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(
            source: "%1$@ could not install the update at %2$@ (%3$@).",
            translation: "%3$@: %1$@ konnte das Update unter %2$@ nicht installieren."
        ))

        let tenArguments = Array(repeating: "%@", count: 10).joined(separator: " ")
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: tenArguments, translation: "%10$@ … %1$@"))
        XCTAssertNotNil(
            FormatSpecifierScanner.mismatch(source: tenArguments, translation: "%11$@"),
            "argument 11 of a 10-argument string must be flagged"
        )
    }

    // MARK: - Corpus languages  (all nine projects)

    /// Every language the nine projects actually localize into has real CLDR
    /// plural data — none falls back to the `other`-only guess. `an`, `ars`,
    /// `ckb`, `kmr` and `oc` (GoMap, damus, apple-browsers) were the gaps this
    /// corpus exposed.
    func testEveryCorpusLanguageHasPluralData() {
        let corpusLanguages = [
            "an", "ar", "ars", "be", "bg", "ca", "ckb", "ckb-IR", "cs", "cy", "da",
            "de", "el", "en", "en-GB", "en-US", "es", "es-AR", "es-MX", "et", "eu",
            "fi", "fr", "ga", "gd", "gl", "he", "hi", "hr", "hu", "hy", "id", "is",
            "it", "ja", "kab", "kmr-TR", "ko", "ku", "ku-TR", "lt", "lv", "mr",
            "my", "nb", "nb-NO", "nl", "nl-BE", "nn", "oc", "pl", "pt", "pt-BR",
            "pt-PT", "ro", "ru", "si", "sk", "sl", "sq", "sv", "ta", "th", "th-TH",
            "tr", "tzm", "uk", "vi", "zh-Hans", "zh-Hant", "zh-Hant-HK",
        ]
        for code in corpusLanguages {
            XCTAssertTrue(PluralRules.isKnown(code), "no CLDR data for \(code)")
        }
        // Najdi Arabic follows Arabic's six categories.
        XCTAssertEqual(
            PluralRules.categories(for: "ars").required,
            ["zero", "one", "two", "few", "many", "other"]
        )
        // Script and region subtags normalise to the base language.
        XCTAssertEqual(PluralRules.baseLanguage("zh-Hant-HK"), "zh")
        XCTAssertEqual(PluralRules.baseLanguage("ckb-IR"), "ckb")
        XCTAssertEqual(PluralRules.baseLanguage("kmr-TR"), "kmr")
    }

    /// damus keeps catalogs whose `sourceLanguage` is `en-US`, with the source
    /// text filed under that exact code. The source language is whatever the
    /// catalog says it is — not "en".
    func testSourceLanguageWithRegionSubtag() throws {
        let catalog = try makeCatalog(sourceLanguage: "en-US", strings: [
            "Save": .object(["localizations": .object([
                "en-US": unit("Save"),
                "ja": unit("保存"),
            ])]),
        ])
        let loaded = try Catalog(path: catalog.path)
        XCTAssertEqual(loaded.sourceLanguage, "en-US")
        XCTAssertEqual(loaded.value("Save", "en-US"), "Save")

        let report = try check(catalog, languages: ["en-US", "ja"]).catalogs[0]
        let source = report.coverage.first { $0.language == "en-US" }
        XCTAssertEqual(source?.isSourceLanguage, true)
        XCTAssertEqual(report.coverage.first { $0.language == "ja" }?.missing, [])
        XCTAssertEqual(PluralRules.categories(for: "en-US").required, ["one", "other"])
    }

    // MARK: - Nested variations (documented, absent from the corpus)

    /// Xcode's editor can vary a string by device and then by plural inside one
    /// device's case. None of the nine projects ships this shape — recorded in
    /// the suite header — but the recursive walks claim to support it, so the
    /// claim is pinned here with the shape Xcode would write.
    func testPluralVariationsNestedInsideDeviceVariations() throws {
        let nested = JSONValue.object(["variations": .object([
            "device": .object([
                "iphone": .object(["variations": .object(["plural": .object([
                    "one": unit("%lld вкладка"),
                    "other": unit("%lld вкладак"),
                ])])]),
                "other": unit("%lld вкладак"),
            ]),
        ])])
        let catalog = try makeCatalog(strings: [
            "%lld tabs": .object(["localizations": .object(["ru": nested])]),
        ])
        let loaded = try Catalog(path: catalog.path)

        let paths = Set(loaded.comparableEntries("%lld tabs", "ru").map(\.path))
        XCTAssertEqual(paths, ["device.iphone.plural.one", "device.iphone.plural.other", "device.other"])

        // Russian needs few and many; the nested plural provides one and other.
        guard case .variations(let missing) = loaded.status("%lld tabs", "ru") else {
            return XCTFail("expected variations status")
        }
        XCTAssertEqual(missing, ["few", "many"])
        XCTAssertTrue(loaded.isPluralised("%lld tabs", "ru"))
    }

    // MARK: - Unknown key-level fields  (HSTracker)

    /// HSTracker's catalogs carry `isCommentAutoGenerated` beside `comment` at
    /// the key level. An edit to that key's translations must not shed it.
    func testKeyLevelUnknownFieldSurvivesEdit() throws {
        let catalog = try makeCatalog(strings: [
            "Deck name": .object([
                "comment": .string("auto"),
                "isCommentAutoGenerated": .bool(true),
                "localizations": .object(["en": unit("Deck name")]),
            ]),
        ])
        var loaded = try Catalog(path: catalog.path)
        try loaded.setTranslation(key: "Deck name", language: "ja", value: "デッキ名", state: .translated)
        let reparsed = try JSONParser.parse(loaded.serialized())
        XCTAssertEqual(
            reparsed["strings"]?["Deck name"]?["isCommentAutoGenerated"]?.boolValue,
            true
        )
        XCTAssertEqual(reparsed["strings"]?["Deck name"]?["comment"]?.stringValue, "auto")
    }

    // MARK: - Helpers (same pattern as RealWorldTests)

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }

    private func substitutionLocalization(
        value: String,
        substitutions: [String: (argNum: Int, specifier: String, plurals: [String: String])]
    ) -> JSONValue {
        var declared: [String: JSONValue] = [:]
        for (name, details) in substitutions {
            var plural: [String: JSONValue] = [:]
            for (category, text) in details.plurals { plural[category] = unit(text) }
            declared[name] = .object([
                "argNum": .number("\(details.argNum)"),
                "formatSpecifier": .string(details.specifier),
                "variations": .object(["plural": .object(plural)]),
            ])
        }
        return .object([
            "stringUnit": .object(["state": .string("translated"), "value": .string(value)]),
            "substitutions": .object(declared),
        ])
    }

    private func makeCatalog(
        named name: String = "Localizable.xcstrings",
        sourceLanguage: String = "en",
        strings: [String: JSONValue]
    ) throws -> URL {
        let url = root.appendingPathComponent("App/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = JSONValue.object([
            "sourceLanguage": .string(sourceLanguage),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        try JSONWriter.text(document).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func check(_ catalog: URL, languages: [String] = []) throws -> CheckReport {
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(
            name: "App",
            sources: [],
            catalogs: [String(catalog.path.dropFirst(root.path.count + 1))]
        )]
        configuration.languages = languages
        let command = CheckCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(languages: languages)
        )
        return try command.run()
    }
}
