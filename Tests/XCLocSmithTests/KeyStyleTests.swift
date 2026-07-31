import XCTest
@testable import XCLocSmithKit

/// Keys that are English sentences, and the translations an edit to one would
/// orphan.
///
/// The check has to stay quiet on the style being legitimate — `"Save"` as its
/// own key is fine and always will be — and speak up where the key is prose,
/// because there the key *is* the content and rewording it is a rename. Whisky,
/// NetNewsWire and Mastodon key by identifier throughout and report nothing.
final class KeyStyleTests: XCTestCase {

    private func catalog(
        _ entries: [String: [String]],
        source: String = "en",
        stale: Set<String> = []
    ) -> Catalog {
        var strings: [String: JSONValue] = [:]
        for (key, languages) in entries {
            var localizations: [String: JSONValue] = [:]
            for language in languages {
                localizations[language] = .object(["stringUnit": .object([
                    "state": .string("translated"), "value": .string("text"),
                ])])
            }
            var entry: [String: JSONValue] = ["localizations": .object(localizations)]
            if stale.contains(key) { entry["extractionState"] = .string("stale") }
            strings[key] = .object(entry)
        }
        return Catalog(path: "/tmp/App/Localizable.xcstrings", sourceLanguage: source, strings: strings)
    }

    // MARK: - What counts as a sentence

    func testShortLabelsAreNeverFlagged() {
        for key in ["Save", "Delete %@", "Show in Finder", "Cold Plunge", "OK"] {
            XCTAssertFalse(KeyStyle.isSentence(key), key)
        }
    }

    func testAnIdentifierIsNeverFlaggedHoweverLong() {
        for key in [
            "session.activitySegments.explanation",
            "settings.notifications.reminders.weeklySummary.footerText",
            "a.b.c.d.e.f.g.h",
        ] {
            XCTAssertFalse(KeyStyle.isSentence(key), key)
        }
    }

    func testASentenceIsFlagged() {
        XCTAssertTrue(KeyStyle.isSentence(
            "Each session is divided into segments: Soak, Cold Plunge, Sauna, and Rest."
        ))
        XCTAssertTrue(KeyStyle.isSentence("This will remove every session you have recorded"))
    }

    /// Five words is the line. Four is still a label somebody wrote once.
    func testTheThresholdIsFiveWords() {
        XCTAssertFalse(KeyStyle.isSentence("Restore from a backup"))          // 4
        XCTAssertTrue(KeyStyle.isSentence("Restore from a local backup"))     // 5
    }

    // MARK: - What is at risk

    func testTheCountIsTheTranslationsThatWouldBeOrphaned() {
        let sentence = "Each session is divided into segments and shown in the flow bar"
        let found = KeyStyle.sentenceKeys(in: catalog([sentence: ["en", "ja", "de", "fr"]]))

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].key, sentence)
        // The source language is not at risk: it is the thing being edited.
        XCTAssertEqual(found[0].translationsAtRisk, 3)
    }

    /// A sentence key nobody has translated has nothing to lose, and advice
    /// with no consequence attached is noise.
    func testAnUntranslatedSentenceKeyIsNotReported() {
        let sentence = "Each session is divided into segments and shown in the flow bar"
        XCTAssertTrue(KeyStyle.sentenceKeys(in: catalog([sentence: ["en"]])).isEmpty)
    }

    /// Xcode is already retiring a stale key; renaming it is wasted work.
    func testStaleKeysAreIgnored() {
        let sentence = "Each session is divided into segments and shown in the flow bar"
        let found = KeyStyle.sentenceKeys(
            in: catalog([sentence: ["en", "ja", "de"]], stale: [sentence])
        )
        XCTAssertTrue(found.isEmpty)
    }

    /// Worst first: the key in thirty-one languages matters more than the one
    /// in two, and a list ordered by path buries it.
    func testTheWidestExposureIsReportedFirst() {
        let small = "Delete this session and everything in it"
        let large = "Each session is divided into segments and shown in the flow bar"
        let found = KeyStyle.sentenceKeys(in: catalog([
            small: ["en", "ja"],
            large: ["en", "ja", "de", "fr", "es"],
        ]))

        XCTAssertEqual(found.map(\.key), [large, small])
        XCTAssertEqual(found.map(\.translationsAtRisk), [4, 1])
    }

    /// A project that keys by identifier should hear nothing at all.
    func testAnIdentifierKeyedCatalogIsSilent() {
        let found = KeyStyle.sentenceKeys(in: catalog([
            "session.activitySegments.explanation": ["en", "ja", "de", "fr"],
            "session.delete.confirmation": ["en", "ja", "de", "fr"],
        ]))
        XCTAssertTrue(found.isEmpty)
    }

    /// A non-English source language is still a source language.
    func testTheSourceLanguageIsExcludedWhateverItIs() {
        let sentence = "Jede Sitzung ist in Abschnitte unterteilt und wird angezeigt"
        let found = KeyStyle.sentenceKeys(
            in: catalog([sentence: ["de", "en", "ja"]], source: "de")
        )
        XCTAssertEqual(found.first?.translationsAtRisk, 2)
    }
}
