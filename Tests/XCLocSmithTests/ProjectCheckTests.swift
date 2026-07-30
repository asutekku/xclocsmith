import XCTest
@testable import XCLocSmithKit

/// Defects between files rather than inside one.
///
/// Neither of these is visible from either side alone: a translation-management
/// system sees a catalog and not the project around it, and Xcode compiles the
/// project and never compares one catalog against another.
final class ProjectCheckTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Info.plist

    /// DuckDuckGo ships `NSLocalNetworkUsageDescription` in its Info.plist and
    /// in none of its catalogs, so that permission prompt is English for every
    /// non-English user.
    func testAPermissionStringMissingFromTheCatalogIsReported() throws {
        try writePlist([
            "NSCameraUsageDescription": "We need the camera to scan codes.",
            "NSLocalNetworkUsageDescription": "We look for devices nearby.",
        ])
        let catalog = try makeCatalog(
            name: "InfoPlist.xcstrings",
            keys: ["NSCameraUsageDescription"]
        )
        let findings = ProjectChecks.infoPlistCoverage(
            targets: [target()],
            catalogs: [catalog],
            configuration: configuration()
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].detail.contains("NSLocalNetworkUsageDescription"), findings[0].detail)
    }

    /// `InfoPlist.xcstrings` is a table source code never names, so its
    /// `tableName` is deliberately nil. Filtering catalogs on that matched
    /// nothing and told every project it had no InfoPlist catalog at all,
    /// including GoMap, which has one.
    func testAnInfoPlistCatalogIsRecognised() throws {
        try writePlist(["NSCameraUsageDescription": "Scanning."])
        let catalog = try makeCatalog(
            name: "InfoPlist.xcstrings",
            keys: ["NSCameraUsageDescription"]
        )
        XCTAssertTrue(ProjectChecks.infoPlistCoverage(
            targets: [target()],
            catalogs: [catalog],
            configuration: configuration()
        ).isEmpty)
    }

    /// `$(PRODUCT_NAME)` is resolved at build time and is not a string anybody
    /// translates.
    func testBuildSettingReferencesAreNotStrings() throws {
        try writePlist(["CFBundleDisplayName": "$(PRODUCT_NAME)"])
        XCTAssertTrue(ProjectChecks.infoPlistCoverage(
            targets: [target()],
            catalogs: [],
            configuration: configuration()
        ).isEmpty)
    }

    /// Deliberately narrow. `CFBundleName` is `$(PRODUCT_NAME)` in almost every
    /// project and `NSHumanReadableCopyright` is legal boilerplate; both fired
    /// on five of six sample projects and said nothing.
    func testOnlyPermissionsAndTheDisplayNameCount() {
        XCTAssertTrue(ProjectChecks.isUserFacingPlistKey("NSCameraUsageDescription"))
        XCTAssertTrue(ProjectChecks.isUserFacingPlistKey("CFBundleDisplayName"))
        XCTAssertFalse(ProjectChecks.isUserFacingPlistKey("CFBundleName"))
        XCTAssertFalse(ProjectChecks.isUserFacingPlistKey("NSHumanReadableCopyright"))
        XCTAssertFalse(ProjectChecks.isUserFacingPlistKey("CFBundleVersion"))
    }

    // MARK: - Language coverage

    /// iOS resolves a language per bundle, not per app. GoMap's GPX widget
    /// carries ten fewer languages than the app around it, so those users get a
    /// translated app with an English widget.
    func testACatalogShippingFewerLanguagesIsReported() throws {
        let main = catalog("App/Localizable.xcstrings", languages: ["en", "de", "ja", "fr"])
        let other = catalog("App/Errors.xcstrings", languages: ["en", "de", "ja", "fr"])
        let widget = catalog("Widget/Localizable.xcstrings", languages: ["en", "de"])

        let findings = ProjectChecks.languageCoverage([main, other, widget])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].rule, .languageCoverageGap)
        XCTAssertTrue(findings[0].detail.contains("Widget/Localizable.xcstrings"), findings[0].detail)
        XCTAssertTrue(findings[0].detail.contains("fr"), findings[0].detail)
    }

    /// One catalog having a language the others do not is that catalog's
    /// business. Most of them having it and one not is a gap.
    func testALanguageOnlyOneCatalogHasIsNotExpectedOfTheRest() throws {
        let main = catalog("App/Localizable.xcstrings", languages: ["en", "de", "ja"])
        let other = catalog("App/Errors.xcstrings", languages: ["en", "de", "ja"])
        let extra = catalog("Extra/Localizable.xcstrings", languages: ["en", "de", "ja", "kmr"])

        XCTAssertTrue(ProjectChecks.languageCoverage([main, other, extra]).isEmpty)
    }

    /// A catalog nobody has started is already reported as missing
    /// translations, and counting it would drag the expected set to nothing.
    func testAnUnstartedCatalogIsIgnored() throws {
        let main = catalog("App/Localizable.xcstrings", languages: ["en", "de", "ja"])
        let other = catalog("App/Errors.xcstrings", languages: ["en", "de", "ja"])
        let fresh = catalog("New/Localizable.xcstrings", languages: ["en"])

        let findings = ProjectChecks.languageCoverage([main, other, fresh])
        XCTAssertTrue(findings.isEmpty, findings.map(\.detail).joined())
    }

    func testASingleCatalogProjectHasNothingToCompareAgainst() throws {
        let only = catalog("App/Localizable.xcstrings", languages: ["en", "de"])
        XCTAssertTrue(ProjectChecks.languageCoverage([only]).isEmpty)
    }

    // MARK: - Helpers

    private func configuration() -> Configuration {
        var configuration = Configuration(root: root.path)
        configuration.targets = [target()]
        return configuration
    }

    private func target() -> Target {
        Target(name: "App", sources: ["App"], catalogs: ["App/InfoPlist.xcstrings"])
    }

    private func writePlist(_ entries: [String: String]) throws {
        let url = root.appendingPathComponent("App/Info.plist")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func makeCatalog(name: String, keys: [String]) throws -> Catalog {
        var strings: [String: JSONValue] = [:]
        for key in keys {
            strings[key] = .object(["localizations": .object([
                "en": .object(["stringUnit": .object([
                    "state": .string("translated"), "value": .string(key),
                ])]),
            ])])
        }
        return Catalog(
            path: root.appendingPathComponent("App/\(name)").path,
            displayPath: "App/\(name)",
            sourceLanguage: "en",
            strings: strings
        )
    }

    /// A catalog carrying one key translated into each named language.
    private func catalog(_ path: String, languages: [String]) -> Catalog {
        var localizations: [String: JSONValue] = [:]
        for language in languages {
            localizations[language] = .object(["stringUnit": .object([
                "state": .string("translated"), "value": .string("text"),
            ])])
        }
        return Catalog(
            path: root.appendingPathComponent(path).path,
            displayPath: path,
            sourceLanguage: "en",
            strings: ["a.key": .object(["localizations": .object(localizations)])]
        )
    }
}
