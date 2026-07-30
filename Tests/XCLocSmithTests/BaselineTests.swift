import XCTest
@testable import XCLocSmithKit

/// Accepting today's findings so tomorrow's can fail the build.
///
/// The point is adoptability. DuckDuckGo's catalogs carry 352 duplicate
/// strings, 166 unlocalized strings and 172 hygiene findings; there is no
/// version of "fix these first" that ends with the check switched on, so the
/// check never gets switched on and the 353rd duplicate arrives unnoticed.
final class BaselineTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func finding(
        _ rule: String,
        key: String = "a.key",
        language: String? = "de",
        level: Finding.Level = .error,
        line: Int? = nil,
        message: String = "something"
    ) -> Finding {
        Finding(
            rule: rule,
            level: level,
            message: message,
            file: "App/Localizable.xcstrings",
            line: line,
            key: key,
            language: language
        )
    }

    func testAcceptedFindingsAreSuppressedAndNewOnesAreNot() {
        let existing = [finding("missing-translation"), finding("end-punctuation", key: "b.key")]
        let baseline = Baseline(findings: existing)

        let result = baseline.apply(to: existing + [finding("format-mismatch", key: "c.key")])
        XCTAssertEqual(result.suppressed, 2)
        XCTAssertEqual(result.reported.map(\.rule), ["format-mismatch"])
        XCTAssertTrue(result.stale.isEmpty)
    }

    /// A line number moves when somebody adds a string above it; a message
    /// changes when this tool improves its wording; a severity changes when the
    /// project changes its mind. None of those make it a different defect.
    func testIdentityIgnoresLineMessageAndSeverity() {
        let baseline = Baseline(findings: [finding("end-punctuation", line: 12, message: "old wording")])
        let moved = finding("end-punctuation", level: .warning, line: 480, message: "new wording")

        XCTAssertEqual(baseline.apply(to: [moved]).suppressed, 1)
    }

    /// The same rule against the same key in two languages is two defects.
    func testLanguageIsPartOfTheIdentity() {
        let baseline = Baseline(findings: [finding("missing-translation", language: "de")])
        let result = baseline.apply(to: [
            finding("missing-translation", language: "de"),
            finding("missing-translation", language: "ja"),
        ])
        XCTAssertEqual(result.suppressed, 1)
        XCTAssertEqual(result.reported.first?.language, "ja")
    }

    /// A baseline nobody prunes stops being a ratchet and becomes a drawer.
    func testEntriesThatMatchNothingAreReportedAsStale() {
        let baseline = Baseline(findings: [
            finding("end-punctuation", key: "fixed.key"),
            finding("end-punctuation", key: "still.broken"),
        ])
        let result = baseline.apply(to: [finding("end-punctuation", key: "still.broken")])

        XCTAssertEqual(result.stale.map(\.key), ["fixed.key"])
    }

    func testRoundTripsThroughTheFile() throws {
        let baseline = Baseline(findings: [
            finding("missing-translation", key: "a.key", language: "ja"),
            finding("format-mismatch", key: "b.key", language: "ru"),
        ])
        let path = root.appendingPathComponent(Baseline.fileName).path
        try baseline.write(to: path, toolVersion: "9.9.9")

        XCTAssertEqual(try Baseline.load(path: path), baseline)
    }

    /// The file is reviewed in pull requests, so it is sorted and readable
    /// rather than hashed — deleting a line un-suppresses a finding, and the
    /// diff says which string stopped being accepted.
    func testTheFileIsSortedAndReadable() throws {
        let baseline = Baseline(findings: [
            finding("z-rule", key: "zzz"),
            finding("a-rule", key: "aaa"),
        ])
        let text = baseline.serialized(toolVersion: "1.0.0")
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "a-rule")).lowerBound,
            try XCTUnwrap(text.range(of: "z-rule")).lowerBound
        )
        XCTAssertTrue(text.contains("\"key\""), text)
    }

    func testAMalformedBaselineIsRejected() throws {
        let path = root.appendingPathComponent(Baseline.fileName)
        try #"{"findings": [{"file": "x"}]}"#.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Baseline.load(path: path.path))

        try "[]".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Baseline.load(path: path.path))
    }

    /// Counts come from the surviving findings, which is only correct because
    /// every report's finding count equals its failures plus its advisories.
    func testTheReportCountsOnlyWhatSurvives() {
        let baseline = Baseline(findings: [finding("missing-translation")])
        let report = BaselinedReport(
            command: "check",
            result: baseline.apply(to: [
                finding("missing-translation"),
                finding("format-mismatch", key: "new.key"),
                finding("near-duplicate", key: "other.key", level: .warning),
            ])
        )
        XCTAssertEqual(report.failures, 1)
        XCTAssertEqual(report.advisories, 1)
        XCTAssertEqual(report.suppressed, 1)
        XCTAssertEqual(report.findings.count, report.failures + report.advisories)
    }

    /// Recording a baseline reports a clean run, and says why — a run that
    /// simply printed "Clean." would read as a project with no problems.
    func testRecordingSuppressesEverythingAndSaysSo() {
        let findings = [finding("missing-translation"), finding("format-mismatch", key: "b")]
        let report = BaselinedReport(
            command: "check",
            result: Baseline.Result(reported: [], suppressed: findings.count, stale: []),
            written: ".xclocsmith-baseline.json"
        )
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.suppressed, 2)
        XCTAssertEqual(report.written, ".xclocsmith-baseline.json")
    }
}
