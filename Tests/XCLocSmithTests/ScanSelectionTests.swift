import XCTest
@testable import XCLocSmithKit

/// `scan --files`: report on the files named, having read the whole project.
///
/// The distinction matters more than it looks. The classifier's accuracy comes
/// almost entirely from what other files say — a `title:` argument is display
/// text because some other file declares the type that receives it, and a bare
/// `"Save".localized` is localized because some other file defines `localized`.
/// A per-file linter that only reads its one file reports strings that are
/// already localized and stays quiet about ones that are not.
final class ScanSelectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOnlyTheNamedFileIsReported() throws {
        try write("App/Edited.swift", "Text(\"Take a bath\")")
        try write("App/Other.swift", "Text(\"Leave the bath\")")
        try makeCatalog(keys: [])

        let report = try scan(files: ["App/Edited.swift"])

        XCTAssertEqual(report.filesScanned, 1)
        XCTAssertEqual(report.missingKeys.map(\.value), ["Take a bath"])
    }

    /// The whole point: a helper defined in a file the report never mentions
    /// still decides how the edited file's string is read.
    ///
    /// `L(_:)` is a localization call only because another file says so. Read
    /// alone, `L("Take a bath")` is an unlabelled argument to an unknown
    /// function, and the string is invisible.
    func testAHelperInAnotherFileStillCounts() throws {
        try write("App/Helpers.swift", """
            func L(_ key: String) -> String {
                NSLocalizedString(key, comment: "")
            }
            """)
        try write("App/Edited.swift", "let label = L(\"Take a bath\")")
        try makeCatalog(keys: [])

        let report = try scan(files: ["App/Edited.swift"])
        XCTAssertEqual(report.missingKeys.map(\.value), ["Take a bath"])

        // And without the helper file in the project, the same scan of the same
        // file finds nothing — which is what a one-file linter would report.
        try FileManager.default.removeItem(at: root.appendingPathComponent("App/Helpers.swift"))
        XCTAssertTrue(try scan(files: ["App/Edited.swift"]).missingKeys.isEmpty)
    }

    /// Nothing references a key cannot be concluded from one file, and the
    /// answer feeds `prune`, which deletes.
    func testOrphansAreNotReportedForASubset() throws {
        try write("App/Edited.swift", "Text(\"Take a bath\")")
        try write("App/Other.swift", "Text(\"Leave the bath\")")
        try makeCatalog(keys: ["Take a bath", "Leave the bath", "Unused string"])

        let narrowed = try scan(files: ["App/Edited.swift"])
        XCTAssertTrue(narrowed.orphans.isEmpty)
        XCTAssertEqual(narrowed.limitedToFiles, ["App/Edited.swift"])

        let whole = try scan(files: [])
        XCTAssertEqual(whole.orphans.flatMap(\.keys), ["Unused string"])
    }

    /// A hook fires on whatever was written. Being handed a README is normal,
    /// so it is said out loud rather than failed on — and said out loud rather
    /// than swallowed, because a typo'd path would otherwise report clean.
    func testAPathOutsideTheSourcesIsReportedWithoutFailing() throws {
        try write("App/Edited.swift", "Text(\"Take a bath\")")
        try makeCatalog(keys: ["Take a bath"])

        let report = try scan(files: ["App/Edited.swift", "README.md"])

        XCTAssertEqual(report.unscannedFiles, ["README.md"])
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.filesScanned, 1)
    }

    func testAbsolutePathsResolve() throws {
        try write("App/Edited.swift", "Text(\"Take a bath\")")
        try makeCatalog(keys: [])

        let absolute = root.appendingPathComponent("App/Edited.swift").path
        XCTAssertEqual(try scan(files: [absolute]).filesScanned, 1)
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCatalog(keys: [String]) throws {
        var strings: [String: JSONValue] = [:]
        for key in keys {
            strings[key] = .object(["localizations": .object([
                "en": .object(["stringUnit": .object([
                    "state": .string("translated"), "value": .string(key),
                ])]),
            ])])
        }
        let document = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        let url = root.appendingPathComponent("App/Localizable.xcstrings")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONWriter.text(document).write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan(files: [String]) throws -> ScanReport {
        var configuration = Configuration(root: root.path)
        configuration.targets = [Target(
            name: "App",
            sources: ["App"],
            catalogs: ["App/Localizable.xcstrings"]
        )]
        let command = ScanCommand(
            workspace: Workspace(configuration: configuration),
            options: .init(files: files)
        )
        return try command.run()
    }
}
