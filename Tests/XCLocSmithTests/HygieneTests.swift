import XCTest
@testable import XCLocSmithKit

/// Mechanical translation defects, and — more importantly — the correct
/// translations each rule must stay quiet about.
///
/// Every rule here is narrower than the obvious version of itself, because
/// punctuation, spacing and repetition are things languages legitimately
/// disagree about. The negative cases below are all real: each one was a false
/// positive this pass produced against the nine-project sample before the rule
/// was narrowed.
final class HygieneTests: XCTestCase {

    private func rules(
        source: String,
        translation: String,
        language: String = "de"
    ) -> [HygieneFinding.Rule] {
        Hygiene.check(key: "k", source: source, translation: translation, language: language)
            .map(\.rule)
    }

    // MARK: - End punctuation

    func testADroppedTrailingColonIsReported() {
        XCTAssertEqual(rules(source: "Server:", translation: "Server"), [.endPunctuation])
        XCTAssertEqual(rules(source: "Really?", translation: "Wirklich"), [.endPunctuation])
    }

    /// Japanese ends a sentence with `。`, Arabic asks with `؟`, Amharic stops
    /// with `።`. Comparing characters instead of classes reports every CJK and
    /// RTL translation in the project.
    func testEquivalentPunctuationInAnotherScriptIsNotAMismatch() {
        XCTAssertTrue(rules(source: "Saved.", translation: "保存しました。", language: "ja").isEmpty)
        XCTAssertTrue(rules(source: "Delete?", translation: "حذف؟", language: "ar").isEmpty)
        XCTAssertTrue(rules(source: "Server:", translation: "サーバー：", language: "ja").isEmpty)
        XCTAssertTrue(rules(source: "Done!", translation: "完了！", language: "ja").isEmpty)
    }

    /// Greek writes its question mark as `;`, so a Greek question ending in a
    /// semicolon answers an English `?` correctly.
    func testGreekQuestionMarkSatisfiesAQuestion() {
        XCTAssertTrue(rules(source: "Delete?", translation: "Διαγραφή;", language: "el").isEmpty)
    }

    /// `…` and `...` are the same mark written two ways.
    func testEllipsisSpellingsAreInterchangeable() {
        XCTAssertTrue(rules(source: "Loading…", translation: "Wird geladen...").isEmpty)
        XCTAssertTrue(rules(source: "Loading...", translation: "Wird geladen…").isEmpty)
    }

    /// A closing quote or bracket sits after the punctuation it belongs to.
    func testPunctuationInsideClosingMarksIsFound() {
        XCTAssertTrue(rules(source: "Really?\"", translation: "Wirklich?\"").isEmpty)
        XCTAssertEqual(rules(source: "Really?\"", translation: "Wirklich\""), [.endPunctuation])
    }

    func testAnUnpunctuatedSourceIsNeverAMismatch() {
        XCTAssertTrue(rules(source: "Save", translation: "Speichern.").isEmpty)
    }

    // MARK: - Whitespace

    /// A trailing space usually separates this string from whatever is drawn
    /// beside it, so a translator tidying it away closes up two words.
    func testTrailingSpaceMismatchIsReported() {
        XCTAssertEqual(rules(source: "Total: ", translation: "Gesamt:"), [.edgeWhitespace])
        XCTAssertEqual(rules(source: "Total:", translation: "Gesamt: "), [.edgeWhitespace])
        XCTAssertTrue(rules(source: "Total: ", translation: "Gesamt: ").isEmpty)
    }

    /// Loop's Arabic "Thickness" is "السماكة\n\n" — two stray line breaks. That
    /// is one defect, and counting the newlines as edge whitespace as well
    /// billed it twice.
    func testStrayNewlinesAreOnlyReportedAsNewlines() {
        XCTAssertEqual(rules(source: "Thickness", translation: "السماكة\n\n", language: "ar"), [.newlineCount])
    }

    func testDoubleSpaceIsReportedOnlyWhenTheSourceHasNone() {
        XCTAssertEqual(rules(source: "One two", translation: "Eins  zwei"), [.doubleSpace])
        XCTAssertTrue(rules(source: "One  two", translation: "Eins  zwei").isEmpty)
    }

    func testLineBreakCountMustMatch() {
        XCTAssertEqual(rules(source: "One\nTwo\nThree", translation: "Eins\nZwei Drei"), [.newlineCount])
        XCTAssertTrue(rules(source: "One\nTwo", translation: "Eins\nZwei").isEmpty)
    }

    // MARK: - Unicode

    func testZeroWidthSpaceIsReported() {
        // Mastodon's Irish translations really do carry these.
        XCTAssertEqual(rules(source: "Block", translation: "Bac\u{200B}", language: "ga"), [.invisibleCharacter])
    }

    /// Zero-width joiners and non-joiners are load-bearing in Persian, the
    /// Indic scripts and every multi-part emoji. Flagging them would report
    /// correct text in the languages least able to argue back.
    func testZeroWidthJoinersAreLeftAlone() {
        XCTAssertTrue(rules(source: "Settings", translation: "تنظیم\u{200C}ها", language: "fa").isEmpty)
        XCTAssertTrue(rules(source: "Family", translation: "👨‍👩‍👧").isEmpty)
    }

    /// An RTL translator adding a left-to-right *mark* around a phone number is
    /// doing the job properly. An override changes the direction of everything
    /// after it, including text this string does not own.
    func testBidiMarksArePermittedAndOverridesAreNot() {
        XCTAssertTrue(rules(source: "Call +1 555", translation: "\u{200E}+1 555 اتصل", language: "ar").isEmpty)
        XCTAssertEqual(rules(source: "Name", translation: "\u{202E}eman", language: "ar"), [.bidiControl])
    }

    func testAnUnclosedEmbeddingIsReported() {
        XCTAssertEqual(rules(source: "Name", translation: "\u{202B}اسم", language: "ar"), [.bidiControl])
        XCTAssertTrue(rules(source: "Name", translation: "\u{202B}اسم\u{202C}", language: "ar").isEmpty)
    }

    func testReplacementCharacterIsReported() {
        XCTAssertEqual(rules(source: "Caf", translation: "Caf\u{FFFD}"), [.replacementCharacter])
    }

    // MARK: - French spacing

    func testFrenchNeedsANonBreakingSpaceBeforeDoublePunctuation() {
        XCTAssertEqual(
            rules(source: "Delete?", translation: "Supprimer ?", language: "fr"),
            [.punctuationSpacing]
        )
        XCTAssertTrue(rules(source: "Delete?", translation: "Supprimer\u{202F}?", language: "fr").isEmpty)
        XCTAssertTrue(rules(source: "Delete?", translation: "Supprimer\u{00A0}?", language: "fr").isEmpty)
    }

    /// Canadian French keeps the rule for `:` alone, so it is left out rather
    /// than half-enforced.
    func testCanadianFrenchIsNotChecked() {
        XCTAssertTrue(rules(source: "Delete?", translation: "Supprimer ?", language: "fr-CA").isEmpty)
    }

    /// A time and a URL are not prose.
    func testColonsInTimesAndURLsAreNotPunctuation() {
        XCTAssertTrue(rules(source: "12:30", translation: "12:30", language: "fr").isEmpty)
        XCTAssertTrue(rules(source: "See https://x.example", translation: "Voir https://x.example", language: "fr").isEmpty)
    }

    // MARK: - Doubled words

    /// GoMap's interface-builder keys really are "Detail Detail", and Loop has
    /// a key called "Fourth Fourth"; every translation repeats the word because
    /// the string does. Comparing against the source removed 24 of GoMap's 26.
    func testAWordDoubledInTheSourceIsNotTheTranslatorsDoing() {
        XCTAssertTrue(rules(source: "Detail Detail", translation: "Detail detail", language: "cs").isEmpty)
    }

    /// Vietnamese "luôn luôn" is "always"; French "vous vous souvenez" is a
    /// reflexive. Both were false positives on the sample.
    func testReduplicationAndReflexivesAreNotDoubledWords() {
        XCTAssertTrue(rules(source: "Always", translation: "luôn luôn", language: "vi").isEmpty)
        XCTAssertTrue(
            rules(source: "You remember", translation: "Vous vous souvenez", language: "fr").isEmpty
        )
    }

    func testAGenuineDoubledWordIsReported() {
        XCTAssertEqual(
            rules(source: "Open the file", translation: "Öffne die die Datei"),
            [.doubledWord]
        )
    }

    // MARK: - Placeholders

    /// Loop's Arabic and Flemish both write "-" for strings nobody has reached
    /// yet. Every other rule then reports a symptom of that.
    func testABareDashIsAPlaceholderNotATranslation() {
        let findings = Hygiene.check(
            key: "k",
            source: "No updates available.",
            translation: "-",
            language: "ar"
        )
        XCTAssertEqual(findings.map(\.rule), [.placeholderTranslation])
    }

    func testWrittenMarkersAreCaught() {
        XCTAssertEqual(rules(source: "Save changes", translation: "TODO"), [.placeholderTranslation])
        XCTAssertEqual(rules(source: "Save changes", translation: "n/a"), [.placeholderTranslation])
    }

    /// A dash translating a dash is a real translation of a dash.
    func testAPunctuationSourceIsNotAPlaceholderSource() {
        XCTAssertTrue(rules(source: "—", translation: "—").isEmpty)
        XCTAssertTrue(rules(source: "1", translation: "1").isEmpty)
    }

    // MARK: - Markdown

    func testADroppedMarkdownLinkIsReported() {
        // DuckDuckGo's Spanish drops one.
        XCTAssertEqual(
            rules(source: "See [our guide](https://x.example)", translation: "Consulta nuestra guía"),
            [.markdown]
        )
    }

    func testUnbalancedEmphasisIsReported() {
        XCTAssertEqual(rules(source: "This is **bold**", translation: "Das ist **fett"), [.markdown])
    }

    /// A translation containing an asterisk for some other reason is not this
    /// tool's business — the check only runs when the source uses Markdown.
    func testAsterisksInAPlainSourceAreIgnored() {
        XCTAssertTrue(rules(source: "Required field", translation: "Pflichtfeld *").isEmpty)
    }

    // MARK: - Grammar agreement

    func testDroppedInflectionMarkupIsReported() {
        XCTAssertEqual(
            rules(source: "^[%lld post](inflect: true)", translation: "%lld Beitrag"),
            [.inflectionDropped]
        )
    }

    // MARK: - Source-side

    func testSourceEllipsisStyleIsReported() {
        let findings = Hygiene.checkSource(key: "k", source: "Loading...", language: "en")
        XCTAssertEqual(findings.map(\.rule), [.ellipsisStyle])
        XCTAssertTrue(Hygiene.checkSource(key: "k", source: "Loading…", language: "en").isEmpty)
    }

    /// Two bare specifiers cannot be reordered, and German, Japanese and
    /// Turkish routinely need to.
    func testUnorderedSpecifiersAreReportedAgainstTheSource() {
        let findings = Hygiene.checkSource(key: "k", source: "%@ of %@", language: "en")
        XCTAssertEqual(findings.map(\.rule), [.unorderedSpecifiers])
        XCTAssertTrue(Hygiene.checkSource(key: "k", source: "%1$@ of %2$@", language: "en").isEmpty)
        XCTAssertTrue(Hygiene.checkSource(key: "k", source: "%@ items", language: "en").isEmpty)
    }

    // MARK: - Plurals

    func testAllPluralFormsIdenticalIsReported() throws {
        let catalog = Catalog(
            path: "/tmp/App/Localizable.xcstrings",
            sourceLanguage: "en",
            strings: ["count %lld": .object(["localizations": .object([
                "ru": .object(["variations": .object(["plural": .object([
                    "one": unit("%lld штук"),
                    "few": unit("%lld штук"),
                    "many": unit("%lld штук"),
                    "other": unit("%lld штук"),
                ])])]),
            ])])]
        )
        let finding = try XCTUnwrap(
            Hygiene.samePlurals(key: "count %lld", catalog: catalog, language: "ru")
        )
        XCTAssertEqual(finding.rule, .samePlurals)
        // Advisory: an abbreviated form is allowed not to inflect, and
        // Mastodon's Arabic "%ldd ago" is deliberately the same in all six.
        XCTAssertFalse(finding.isFailure)
    }

    /// A language needing only `one` and `other` cannot fail this, and neither
    /// can one with two filled rows — the check takes at least three.
    func testTwoFormLanguagesAreNotChecked() {
        let catalog = Catalog(
            path: "/tmp/App/Localizable.xcstrings",
            sourceLanguage: "en",
            strings: ["count %lld": .object(["localizations": .object([
                "de": .object(["variations": .object(["plural": .object([
                    "one": unit("%lld Stück"),
                    "other": unit("%lld Stück"),
                ])])]),
            ])])]
        )
        XCTAssertNil(Hygiene.samePlurals(key: "count %lld", catalog: catalog, language: "de"))
    }

    // MARK: - Severity

    /// The split is by what a user sees. A mature catalog has hundreds of the
    /// advisory kind, and failing on those means the group gets switched off on
    /// exactly the projects that need it.
    func testSeveritySplit() {
        XCTAssertTrue(HygieneFinding.Rule.replacementCharacter.isFailure)
        XCTAssertTrue(HygieneFinding.Rule.placeholderTranslation.isFailure)
        XCTAssertTrue(HygieneFinding.Rule.markdown.isFailure)
        XCTAssertFalse(HygieneFinding.Rule.endPunctuation.isFailure)
        XCTAssertFalse(HygieneFinding.Rule.punctuationSpacing.isFailure)
        XCTAssertFalse(HygieneFinding.Rule.samePlurals.isFailure)
    }

    func testEveryRuleHasASummary() {
        for rule in HygieneFinding.Rule.allCases {
            XCTAssertFalse(rule.summary.isEmpty, rule.rawValue)
        }
    }

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }
}
