import XCTest
@testable import XCLocSmithKit

/// One source string entered under several keys, and the glossary that fixes
/// how particular terms translate.
///
/// Both findings only exist on projects that key by identifier: where the key
/// *is* the English string, two keys cannot share a source text. The shapes
/// below are taken from Whisky, IceCubesApp and GoMap, where the divergences
/// were real — Whisky's German renders one "Remove" as "Löschen" (delete) and
/// the other as "Entfernen", and GoMap's two location-permission strings carry
/// differently-worded Spanish, one of them with a grammatical error the other
/// does not have.
final class ConsistencyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Duplicate source strings

    /// Whisky: `button.removeAlert.delete` and `environment.remove` are both
    /// "Remove", and German translates them as two different verbs.
    func testTwoKeysWithOneSourceStringAreGroupedWithTheirDivergence() throws {
        let catalog = try makeCatalog(strings: [
            "button.removeAlert.delete": localized(["en": "Remove", "de": "Löschen"]),
            "environment.remove": localized(["en": "Remove", "de": "Entfernen"]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].text, "Remove")
        XCTAssertEqual(duplicates[0].keys, ["button.removeAlert.delete", "environment.remove"])
        XCTAssertEqual(duplicates[0].divergences.map(\.language), ["de"])
        XCTAssertEqual(
            duplicates[0].divergences[0].renderings.map(\.value),
            ["Löschen", "Entfernen"]
        )
    }

    /// Mastodon runs its translations through a memory that propagates them, so
    /// its 62 duplicate groups all agree. The group is still worth naming — it
    /// is one string to change, not three — but there is nothing wrong with it.
    func testDuplicatesThatAgreeAreReportedWithoutADivergence() throws {
        let catalog = try makeCatalog(strings: [
            "Scene.Profile.SegmentedControl.About": localized(["en": "About", "ja": "概要"]),
            "Scene.Settings.AboutMastodon.Title": localized(["en": "About", "ja": "概要"]),
        ])
        let report = try check(catalog, languages: ["en", "ja"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertTrue(duplicates[0].divergences.isEmpty)
    }

    /// Short strings are the ones most likely to be entered twice — "Apply",
    /// "Done", "Retry" — and near-duplicate detection cannot look at them,
    /// because edit distance between two five-character strings is noise. An
    /// exact match needs no threshold.
    func testShortStringsAreCompared() throws {
        let catalog = try makeCatalog(strings: [
            "foo.bar.apply": localized(["en": "Apply", "ja": "適用"]),
            "bar.foo.apply": localized(["en": "Apply", "ja": "適用する"]),
        ])
        let report = try check(catalog, languages: ["en", "ja"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].text, "Apply")
        XCTAssertEqual(duplicates[0].divergences.map(\.language), ["ja"])
        // Too short for the similarity pass, which is exactly why this exists.
        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).similarKeys.isEmpty)
    }

    /// A group where only one key is translated is missing work, and missing
    /// work is already reported as missing work. Calling it a divergence too
    /// would bill one defect twice.
    func testOneTranslatedKeyAndOneUntranslatedIsNotADivergence() throws {
        let catalog = try makeCatalog(strings: [
            "a.done": localized(["en": "Done", "ja": "完了"]),
            "b.done": localized(["en": "Done"]),
        ])
        let report = try check(catalog, languages: ["en", "ja"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertTrue(duplicates[0].divergences.isEmpty)
        let japanese = try XCTUnwrap(
            try XCTUnwrap(report.catalogs.first).coverage.first { $0.language == "ja" }
        )
        XCTAssertEqual(japanese.missing, ["b.done"])
    }

    /// "Free" the price and "Free" the availability are one English string with
    /// two right answers, and a project that has shipped for years has hundreds
    /// of them. `ignoreSimilar` already exists to record that decision.
    func testAnIgnoredPairIsNotReported() throws {
        let catalog = try makeCatalog(strings: [
            "price.free": localized(["en": "Free", "de": "Kostenlos"]),
            "slot.free": localized(["en": "Free", "de": "Frei"]),
        ])
        var configuration = baseConfiguration()
        configuration.ignoredSimilarPairs = [SimilarKeys.canonicalPair("price.free", "slot.free")]
        let report = try check(catalog, languages: ["en", "de"], configuration: configuration)

        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).duplicateSources.isEmpty)
    }

    /// Ignoring a pair silences that pair, not the namespace. Adding a third
    /// key brings the group back, because the third key was never reviewed.
    func testAddingAKeyToAnIgnoredPairBringsTheGroupBack() throws {
        let catalog = try makeCatalog(strings: [
            "price.free": localized(["en": "Free", "de": "Kostenlos"]),
            "slot.free": localized(["en": "Free", "de": "Frei"]),
            "trial.free": localized(["en": "Free", "de": "Gratis"]),
        ])
        var configuration = baseConfiguration()
        configuration.ignoredSimilarPairs = [SimilarKeys.canonicalPair("price.free", "slot.free")]
        let report = try check(catalog, languages: ["en", "de"], configuration: configuration)

        XCTAssertEqual(try XCTUnwrap(report.catalogs.first).duplicateSources.count, 1)
    }

    /// A duplicate is a note, not a failure: it names work to consider, and a
    /// mature catalog has too many for a build to stop on. `--strict` is the
    /// switch for anyone who disagrees.
    func testDuplicatesAreAdvisory() throws {
        let catalog = try makeCatalog(strings: [
            "a.remove": localized(["en": "Remove", "de": "Löschen"]),
            "b.remove": localized(["en": "Remove", "de": "Entfernen"]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.advisories, 1)
    }

    /// Xcode is retiring a stale key, so pairing it with a live one sends
    /// somebody to reconcile a string that is about to be deleted.
    func testStaleAndUntranslatableKeysAreLeftOut() throws {
        let catalog = try makeCatalog(strings: [
            "a.remove": localized(["en": "Remove", "de": "Löschen"]),
            "b.remove": .object([
                "extractionState": .string("stale"),
                "localizations": .object([
                    "en": unit("Remove"),
                    "de": unit("Entfernen"),
                ]),
            ]),
            "c.remove": .object([
                "shouldTranslate": .bool(false),
                "localizations": .object(["en": unit("Remove")]),
            ]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).duplicateSources.isEmpty)
    }

    /// The near-duplicate pass would otherwise report the same finding as a
    /// pair, at 100%, once for every combination — a string under four keys is
    /// one group here and six pairs there.
    func testExactMatchesAreNotAlsoReportedAsNearDuplicates() throws {
        let catalog = try makeCatalog(strings: [
            "one.continue": localized(["en": "Continue"]),
            "two.continue": localized(["en": "Continue"]),
            "three.continue": localized(["en": "Continue"]),
        ])
        let report = try check(catalog, languages: ["en"])
        let catalogReport = try XCTUnwrap(report.catalogs.first)

        XCTAssertEqual(catalogReport.duplicateSources.count, 1)
        XCTAssertEqual(catalogReport.duplicateSources[0].keys.count, 3)
        XCTAssertTrue(catalogReport.similarKeys.isEmpty)
    }

    /// Two identifier keys whose English differs only in case are not
    /// case-duplicate *keys*, so `caseDuplicates` never sees them and the
    /// similarity pass has to keep them.
    func testTextsDifferingOnlyInCaseStayWithTheNearDuplicates() throws {
        let catalog = try makeCatalog(strings: [
            "one.heading": localized(["en": "Heart Rate"]),
            "two.heading": localized(["en": "Heart rate"]),
        ])
        let report = try check(catalog, languages: ["en"])
        let catalogReport = try XCTUnwrap(report.catalogs.first)

        XCTAssertTrue(catalogReport.duplicateSources.isEmpty)
        XCTAssertEqual(catalogReport.similarKeys.count, 1)
    }

    /// IceCubesApp: the English of `trending-tag-people-talking %lld` was
    /// changed to "%lld posts" and the Belarusian was never revisited, so it
    /// still reads "%lld people talking". Nothing in the catalog marks it —
    /// the state says `translated` — and it only shows up beside the other key
    /// that now carries the same English.
    func testAStaleTranslationSurfacesAgainstItsTwin() throws {
        let catalog = try makeCatalog(strings: [
            "account.detail.featured-tags-n-posts %lld": localized([
                "en": "%lld posts", "be": "%lld допісаў",
            ]),
            "trending-tag-people-talking %lld": localized([
                "en": "%lld posts", "be": "%lld people talking",
            ]),
        ])
        let report = try check(catalog, languages: ["en", "be"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].divergences.map(\.language), ["be"])
    }

    /// Groups that disagree are the ones somebody has to act on, so they lead.
    func testDivergentGroupsSortAboveAgreeingOnes() throws {
        let catalog = try makeCatalog(strings: [
            "a.about": localized(["en": "About", "de": "Über"]),
            "b.about": localized(["en": "About", "de": "Über"]),
            "a.remove": localized(["en": "Remove", "de": "Löschen"]),
            "b.remove": localized(["en": "Remove", "de": "Entfernen"]),
        ])
        let report = try check(catalog, languages: ["en", "de"])
        let duplicates = try XCTUnwrap(report.catalogs.first).duplicateSources

        XCTAssertEqual(duplicates.map(\.text), ["Remove", "About"])
    }

    // MARK: - Glossary

    func testATermMissingFromATranslationIsAFailure() throws {
        let catalog = try makeCatalog(strings: [
            "session.new": localized(["en": "New onsen session", "ja": "新しいセッション"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Onsen": ["ja": "温泉"]])
        let report = try check(catalog, languages: ["en", "ja"], configuration: configuration)
        let violations = try XCTUnwrap(report.catalogs.first).glossaryViolations

        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations[0].term, "Onsen")
        XCTAssertEqual(violations[0].expected, "温泉")
        XCTAssertEqual(violations[0].translation, "新しいセッション")
        // Opt-in, so a violation is a decision the project wrote down.
        XCTAssertEqual(report.failures, 1)
    }

    func testATermPresentInTheTranslationPasses() throws {
        let catalog = try makeCatalog(strings: [
            "session.new": localized(["en": "New onsen session", "ja": "新しい温泉セッション"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Onsen": ["ja": "温泉"]])
        let report = try check(catalog, languages: ["en", "ja"], configuration: configuration)

        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).glossaryViolations.isEmpty)
    }

    /// `*` is how a product name that must survive every language is written.
    func testTheWildcardLanguageAppliesEverywhere() throws {
        let catalog = try makeCatalog(strings: [
            "app.name": localized(["en": "Furolog", "ja": "フロログ", "de": "Furolog"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Furolog": ["*": "Furolog"]])
        let report = try check(catalog, languages: ["en", "ja", "de"], configuration: configuration)
        let violations = try XCTUnwrap(report.catalogs.first).glossaryViolations

        XCTAssertEqual(violations.map(\.language), ["ja"])
    }

    /// A named language beats the wildcard, so one language can be allowed to
    /// transliterate a name that every other language must leave alone.
    func testANamedLanguageOverridesTheWildcard() throws {
        let catalog = try makeCatalog(strings: [
            "app.name": localized(["en": "Furolog", "ja": "フロログ", "de": "Furolog"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Furolog": ["*": "Furolog", "ja": "フロログ"]])
        let report = try check(catalog, languages: ["en", "ja", "de"], configuration: configuration)

        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).glossaryViolations.isEmpty)
    }

    /// `pt-BR` inherits `pt` unless it says otherwise, matching how the rest of
    /// the tool reads language codes.
    func testARegionalCodeInheritsTheBaseLanguage() throws {
        let catalog = try makeCatalog(strings: [
            "app.tagline": localized(["en": "Track your onsen", "pt-BR": "Acompanhe seu banho"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Onsen": ["pt": "onsen"]])
        let report = try check(catalog, languages: ["en", "pt-BR"], configuration: configuration)

        XCTAssertEqual(try XCTUnwrap(report.catalogs.first).glossaryViolations.count, 1)
    }

    /// A term is a word, not a substring: "Loop" must not fire on "Looping".
    func testTermsMatchOnWordBoundaries() throws {
        XCTAssertTrue(Consistency.contains(term: "Loop", in: "Start a Loop now"))
        XCTAssertTrue(Consistency.contains(term: "Loop", in: "loop"))
        XCTAssertTrue(Consistency.contains(term: "Loop", in: "Open Loop."))
        XCTAssertFalse(Consistency.contains(term: "Loop", in: "Looping forever"))
        XCTAssertFalse(Consistency.contains(term: "Loop", in: "Bloop"))
        // Japanese does not separate words, so every character of
        // 新しい温泉セッション is a letter and a boundary rule built on `isLetter`
        // finds nothing at all. The same rule must not stop a Latin name being
        // found where a particle is attached straight onto it.
        XCTAssertTrue(Consistency.contains(term: "温泉", in: "新しい温泉セッション"))
        XCTAssertTrue(Consistency.contains(term: "Furolog", in: "Furologを開く"))
        XCTAssertTrue(Consistency.contains(term: "Furolog", in: "Furolog을 시작"))
    }

    /// A glossary is a set of decisions, and "furolog" is not the name of the
    /// product.
    func testTheExpectedRenderingIsCaseSensitive() throws {
        let catalog = try makeCatalog(strings: [
            "app.name": localized(["en": "Furolog", "de": "furolog"]),
        ])
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Furolog": ["*": "Furolog"]])
        let report = try check(catalog, languages: ["en", "de"], configuration: configuration)

        XCTAssertEqual(try XCTUnwrap(report.catalogs.first).glossaryViolations.count, 1)
    }

    /// A malformed glossary that loaded as empty would leave the check silently
    /// doing nothing, which is the one outcome nobody would notice.
    func testAMalformedGlossaryIsRejected() throws {
        let path = root.appendingPathComponent(Configuration.fileName)
        try #"{"glossary": {"Onsen": "温泉"}}"#.write(to: path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try Configuration.load(explicitPath: path.path, useConfigFile: true, workingDirectory: root.path)
        ) { error in
            XCTAssertTrue("\(error)".contains("Onsen"), "\(error)")
        }
    }

    func testAGlossaryRoundTripsThroughTheConfiguration() throws {
        var configuration = baseConfiguration()
        configuration.glossary = Glossary(terms: ["Onsen": ["ja": "温泉", "*": "onsen"]])
        let path = root.appendingPathComponent(Configuration.fileName)
        try configuration.serialized().write(to: path, atomically: true, encoding: .utf8)

        let reloaded = try Configuration.load(
            explicitPath: path.path,
            useConfigFile: true,
            workingDirectory: root.path
        )
        XCTAssertEqual(reloaded.glossary.terms["Onsen"], ["ja": "温泉", "*": "onsen"])
    }

    // MARK: - Helpers

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }

    private func localized(_ values: [String: String]) -> JSONValue {
        .object(["localizations": .object(values.mapValues { unit($0) })])
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
        configuration.targets = [Target(name: "App", sources: [], catalogs: ["App/Localizable.xcstrings"])]
        return configuration
    }

    private func check(
        _ catalog: URL,
        languages: [String] = [],
        configuration: Configuration? = nil
    ) throws -> CheckReport {
        var resolved = configuration ?? baseConfiguration()
        resolved.languages = languages
        let command = CheckCommand(
            workspace: Workspace(configuration: resolved),
            options: .init(languages: languages)
        )
        return try command.run()
    }
}
