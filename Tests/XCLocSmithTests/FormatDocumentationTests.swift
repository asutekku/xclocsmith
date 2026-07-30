import XCTest
@testable import XCLocSmithKit

/// Pins the format-specifier model against Apple's own documentation.
///
/// Sources:
/// - "String Format Specifiers" (developer.apple.com/library/archive/documentation/
///   Cocoa/Conceptual/Strings/Articles/formatSpecifiers.html) — the conversion and
///   length-modifier tables, and the `n$` positional note.
/// - `String.LocalizationValue.Placeholder` (sosumi.ai/documentation/swift/string/
///   localizationvalue/placeholder) — the five placeholder types Xcode's extractor
///   emits specifiers for: int, uint, float, double, object.
/// - WWDC23 "Discover String Catalogs" (sosumi.ai/videos/play/wwdc2023/10155) —
///   extraction states, translation states, substitution shape.
/// - Automatic Grammar Agreement `^[...](inflect: true)` — WWDC23 "Unlock the
///   power of grammatical agreement" and the AttributedString `inflected()` docs.
final class FormatDocumentationTests: XCTestCase {

    // MARK: - Apple's conversion table

    /// Every conversion Apple documents for user-facing strings is recognised,
    /// and lands in the conversion class that decides argument compatibility.
    func testDocumentedConversionsAreRecognised() {
        let expectations: [(String, String)] = [
            ("%@", "object"),
            ("%d", "integer"), ("%D", "integer"), ("%i", "integer"),
            ("%u", "integer"), ("%U", "integer"),
            ("%x", "integer"), ("%X", "integer"),
            ("%o", "integer"), ("%O", "integer"),
            ("%f", "float"), ("%F", "float"),
            ("%e", "float"), ("%E", "float"),
            ("%g", "float"), ("%G", "float"),
            ("%c", "character"), ("%C", "character"),
            ("%s", "cstring"), ("%S", "cstring"),
        ]
        for (raw, expectedClass) in expectations {
            let found = FormatSpecifierScanner.specifiers(in: "value: \(raw)!")
            XCTAssertEqual(found.count, 1, "\(raw) not recognised as a specifier")
            XCTAssertEqual(found.first?.conversionClass, expectedClass, "wrong class for \(raw)")
        }
    }

    /// Apple's length-modifier table: h, hh, l, ll, q, z, t, j, L. Each one
    /// attaches to its conversion instead of splitting into garbage.
    func testDocumentedLengthModifiersAreRecognised() {
        for spelled in ["%hd", "%hhd", "%ld", "%lld", "%qd", "%zd", "%td", "%jd", "%Lf"] {
            let found = FormatSpecifierScanner.specifiers(in: spelled)
            XCTAssertEqual(found.count, 1, "\(spelled) not recognised")
            XCTAssertEqual(found.first?.raw, spelled)
        }
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%hhd").first?.length, "hh")
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%lld").first?.length, "ll")
    }

    /// Flags, width and precision from the printf grammar Apple points at:
    /// `%.2f`, `%05d`, `%'d`, `%-10@` are one specifier each, not noise.
    func testFlagsWidthAndPrecisionAreAccepted() {
        for (text, conversionClass) in [
            ("%.2f", "float"), ("%05d", "integer"), ("%'d", "integer"), ("%-10@", "object"),
            ("%+d", "integer"), ("%#x", "integer"),
        ] {
            let found = FormatSpecifierScanner.specifiers(in: text)
            XCTAssertEqual(found.count, 1, "\(text) not recognised")
            XCTAssertEqual(found.first?.conversionClass, conversionClass)
        }
    }

    /// Deliberate deviations from Apple's table, kept and pinned:
    ///
    /// - `%p` (void pointer) and `%a`/`%A` (hex float) are documented by Apple
    ///   but excluded here on purpose — they never appear in UI strings, while
    ///   `%arg` (Xcode's substitution token) and prose like "50% of" do, and
    ///   would misparse as `%a`/`% o` if the grammar accepted them.
    /// - The space flag (`% d`) is legal printf and excluded for the same
    ///   reason: "100% private" is prose, not a conversion.
    func testDeliberateExclusionsFromApplesTable() {
        for excluded in ["%p", "%a", "%A", "% d", "%n"] {
            XCTAssertTrue(
                FormatSpecifierScanner.specifiers(in: excluded).isEmpty,
                "\(excluded) is deliberately not a specifier in catalog prose"
            )
        }
    }

    // MARK: - String.LocalizationValue placeholders

    /// The five `String.LocalizationValue.Placeholder` cases map to the
    /// specifiers Xcode writes into extracted keys: object → `%@`,
    /// int → `%lld`, uint → `%llu`, double → `%lf`, float → `%f`.
    /// All five must parse, and the numeric ones must land in classes such
    /// that int/uint compare as integers and double/float as floats.
    func testLocalizationValuePlaceholderSpecifiersParse() {
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%@").first?.conversionClass, "object")
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%lld").first?.conversionClass, "integer")
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%llu").first?.conversionClass, "integer")
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%lf").first?.conversionClass, "float")
        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: "%f").first?.conversionClass, "float")

        // Apple's platform-dependent table: %lf is a double, %f a CGFloat —
        // a translation swapping one for the other reads the same argument.
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: "%lf°", translation: "%f度"))
        // But an integer for a float is a genuine class change.
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(source: "%lf°", translation: "%lld度"))
    }

    // MARK: - Positional specifiers

    /// Apple: "you can also use the n$ positional specifiers such as %1$@ %2$s".
    /// A positional translation is compared argument-by-argument against the
    /// source's order, so `%2$@ %1$lld` against `%lld %@` is correct.
    func testPositionalSpecifiersCompareByArgumentPosition() {
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: "%lld by %@", translation: "%2$@ — %1$lld"))
        XCTAssertNotNil(
            FormatSpecifierScanner.mismatch(source: "%lld by %@", translation: "%2$lld — %1$@"),
            "swapped conversion classes behind the positions must be caught"
        )
    }

    // MARK: - Automatic Grammar Agreement

    /// `^[...](inflect: true)` is Markdown syntax Foundation strips at render
    /// time; this tool does not model it (a known, harmless gap). What must
    /// hold: the specifiers *inside* the inflected span are still found, the
    /// syntax itself is never misread as a specifier, and two localizations
    /// that both carry the syntax compare clean.
    func testInflectSyntaxIsCarriedThroughNotMangled() {
        let source = "^[%lld Files](inflect: true) selected"
        let spanish = "^[%lld archivos](inflect: true) seleccionados"

        XCTAssertEqual(FormatSpecifierScanner.specifiers(in: source).map(\.raw), ["%lld"])
        XCTAssertNil(FormatSpecifierScanner.mismatch(source: source, translation: spanish))
        // Dropping the count inside an inflected span is still a real defect.
        XCTAssertNotNil(FormatSpecifierScanner.mismatch(
            source: source,
            translation: "^[archivos](inflect: true)"
        ))
        // The `(inflect: true)` suffix contains no `%`, so it can never collide
        // with the specifier grammar even next to punctuation-heavy prose.
        XCTAssertTrue(FormatSpecifierScanner.specifiers(in: "^[them](inflect: true)").isEmpty)
    }

    // MARK: - Plural categories per Apple's own example

    /// The string-catalog tutorial's worked example: English varies by One and
    /// Other; "Russian … One, Few, Many, and Other". Japanese has no plural
    /// distinction, which is why one filled row completes it.
    func testPluralCategoriesMatchApplesWorkedExample() {
        XCTAssertEqual(PluralRules.categories(for: "en").required, ["one", "other"])
        XCTAssertEqual(PluralRules.categories(for: "ru").required, ["one", "few", "many", "other"])
        XCTAssertEqual(PluralRules.categories(for: "ja").required, ["other"])
    }

    // MARK: - xcstringstool symbol eligibility

    /// `xcstringstool generate-symbols --help`: "Generates symbols for
    /// manually-defined strings." Only `extractionState: manual` is eligible —
    /// extracted, migrated and stale strings never produce symbols, so only
    /// manual keys can collide by case at build time.
    func testOnlyManualStringsAreSymbolEligible() {
        XCTAssertTrue(ExtractionState.manual.isSymbolEligible)
        XCTAssertFalse(ExtractionState.migrated.isSymbolEligible)
        XCTAssertFalse(ExtractionState.extractedWithValue.isSymbolEligible)
        XCTAssertFalse(ExtractionState.stale.isSymbolEligible)
    }
}
