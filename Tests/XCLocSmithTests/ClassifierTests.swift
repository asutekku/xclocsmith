import XCTest
@testable import XCLocSmithKit

/// This table *is* the specification for what counts as a user-visible string.
///
/// Rows are Swift *fragments*, not compilable files — the lexer only needs the
/// shape of the call. The expectation is what `xcstringstool extract` would put
/// in the catalog for that shape.
final class ClassifierTests: XCTestCase {

    private func keys(_ source: String, configuration: Configuration = .test) -> [String] {
        analyze(source, configuration: configuration).strings.map(\.value)
    }

    private func analyze(_ source: String, configuration: Configuration = .test) -> SourceScanResult {
        let file = AnalyzedSource(path: "/tmp/T.swift", displayPath: "T.swift", text: source)
        let discovered = LocalizableDiscovery.discover(in: [file])
        return SourceAnalyzer.analyze(
            file: file,
            discovered: discovered,
            options: configuration.classifierOptions,
            includePreviews: false,
            ignoredStrings: []
        )
    }

    // MARK: - SwiftUI

    func testSwiftUIInitializers() {
        XCTAssertEqual(keys(#"Text("Hello")"#), ["Hello"])
        XCTAssertEqual(keys(#"Button("Save") { }"#), ["Save"])
        XCTAssertEqual(keys(#"Label("Photos", systemImage: "photo")"#), ["Photos"])
        XCTAssertEqual(keys(#"Toggle("Enabled", isOn: $flag)"#), ["Enabled"])
    }

    func testModifiers() {
        XCTAssertEqual(keys(#"view.navigationTitle("Screen")"#), ["Screen"])
        XCTAssertEqual(keys(#"view.accessibilityLabel("Close")"#), ["Close"])
        XCTAssertEqual(keys(#"view.alert("Careful", isPresented: $shown) { }"#), ["Careful"])
    }

    /// A literal that is only *part* of the argument is still user-visible.
    /// Walking backwards from the literal cannot see this, which is why the
    /// argument list is parsed forwards.
    func testTernaryAndNilCoalescing() {
        XCTAssertEqual(keys(#"Text(flag ? "Yes" : "No")"#).sorted(), ["No", "Yes"])
        XCTAssertEqual(keys(#"Text(name ?? "Unknown")"#), ["Unknown"])
        XCTAssertEqual(keys(#"Button(flag ? "Start" : "Stop") { }"#).sorted(), ["Start", "Stop"])
    }

    // MARK: - Foundation

    func testFoundationAPIs() {
        XCTAssertEqual(keys(#"String(localized: "Foundation Key")"#), ["Foundation Key"])
        XCTAssertEqual(keys(#"AttributedString(localized: "Attributed")"#), ["Attributed"])
        XCTAssertEqual(keys(#"NSLocalizedString("Legacy", comment: "note")"#), ["Legacy"])
        XCTAssertEqual(keys(#"LocalizedStringResource("Resource")"#), ["Resource"])
    }

    /// `comment:` and `defaultValue:` are never keys.
    func testValueLabelsAreNotKeys() {
        XCTAssertEqual(keys(#"NSLocalizedString("Key", comment: "explanatory note")"#), ["Key"])
        XCTAssertEqual(keys(#"String(localized: "Key", defaultValue: "Default text")"#), ["Key"])
    }

    // MARK: - Tables

    func testTableNameIsCaptured() {
        let found = analyze(#"Text("Failed", tableName: "Errors")"#).strings
        XCTAssertEqual(found.map(\.table), ["Errors"])
        let untabled = analyze(#"Text("Plain")"#).strings
        XCTAssertEqual(untabled.map(\.table), [nil])
    }

    func testDynamicTableIsFlagged() {
        XCTAssertTrue(analyze(#"Text("Key", tableName: someTable)"#).hasDynamicTables)
    }

    // MARK: - Not user-visible

    func testIdentifiersAndAssetNames() {
        XCTAssertEqual(keys(#"Image("decorative-asset")"#), [])
        XCTAssertEqual(keys(#"Image(systemName: "chevron.right")"#), [])
        XCTAssertEqual(keys(#"UserDefaults.standard.set(1, forKey: "counter")"#), [])
        XCTAssertEqual(keys(#"let ids = ["alpha", "beta"]"#), [])
        XCTAssertEqual(keys(#"view.tag("selection")"#), [])
    }

    func testVerbatimIsABypassNotAKey() {
        let result = analyze(#"Text(verbatim: "Raw")"#)
        XCTAssertTrue(result.strings.isEmpty)
        XCTAssertEqual(result.bypasses.count, 1)
    }

    func testUIKitAssignmentIsABypass() {
        let result = analyze(#"label.text = "Hardcoded""#)
        XCTAssertTrue(result.strings.isEmpty)
        XCTAssertEqual(result.bypasses.first?.reason.contains("String(localized:)"), true)
    }

    /// A concatenated fragment is a bypass and nothing else.
    ///
    /// `Text("Prefix " + name)` resolves to the `String` overload, so Xcode
    /// extracts nothing — there is no key to be missing. Reporting one told
    /// HSTracker's translators to add "Are you sure you want to delete " to the
    /// catalog, when the fix is to stop building the sentence by concatenation.
    func testConcatenationIsOnlyABypass() {
        let result = analyze(#"Text("Prefix " + name)"#)
        XCTAssertEqual(result.strings.map(\.value), [])
        XCTAssertEqual(result.bypasses.count, 1)
        // Still counts as a reference, so the fragment is never called orphaned.
        XCTAssertTrue(result.referencedValues.contains("Prefix "))
    }

    // MARK: - Project conventions

    /// A view that renders its `String` through `LocalizedStringKey` makes its
    /// call sites localizable; the same parameter name on a type that does not
    /// is an internal identifier.
    func testDiscoveredParametersAreTypeAware() {
        let source = """
            struct StatRow: View {
                let label: String
                var body: some View { Text(LocalizedStringKey(label)) }
            }
            struct Internal: View {
                let label: String
                var body: some View { Text(verbatim: label) }
            }
            struct Screen: View {
                var body: some View {
                    StatRow(label: "Best Drop")
                    Internal(label: "row-identifier")
                }
            }
            """
        XCTAssertEqual(keys(source), ["Best Drop"])
    }

    func testPreviewsAreSkippedByDefault() {
        let source = """
            struct V: View { var body: some View { Text("Shipped") } }
            #Preview { Text("Sample") }
            """
        XCTAssertEqual(keys(source), ["Shipped"])
    }

    func testInterpolatedLiteralsBecomeFormatKeys() {
        let found = analyze(#"Text("Hello \(name)")"#).strings
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].isFormatKey)
        XCTAssertNotNil(found[0].formatPattern)
    }
}

extension Configuration {
    static var test: Configuration {
        Configuration(root: "/tmp")
    }
}
