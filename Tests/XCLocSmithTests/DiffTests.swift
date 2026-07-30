import XCTest
@testable import XCLocSmithKit

/// Comparing two versions of a catalog.
///
/// The finding under test throughout is a source string that moved while its
/// translations stayed put. It is invisible in the catalog — the states all say
/// `translated` — and invisible in `git diff`, which shows the English line
/// changing and cannot say which of the nineteen translations below it were
/// left behind.
final class DiffTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The IceCubesApp shape: English becomes "%lld posts" and the Belarusian
    /// still reads "%lld people talking".
    func testASourceChangeWithUnchangedTranslationsIsAFailure() throws {
        let before = catalog([
            "trending-tag-people-talking %lld": localized([
                "en": "%lld people talking", "be": "%lld размаўляюць", "de": "%lld sprechen",
            ]),
        ])
        let after = catalog([
            "trending-tag-people-talking %lld": localized([
                "en": "%lld posts", "be": "%lld размаўляюць", "de": "%lld Beiträge",
            ]),
        ])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceChanges.count, 1)
        let change = try XCTUnwrap(diff.sourceChanges.first)
        XCTAssertEqual(change.before, "%lld people talking")
        XCTAssertEqual(change.after, "%lld posts")
        XCTAssertEqual(change.staleLanguages, ["be"])
        XCTAssertEqual(change.updatedLanguages, ["de"])

        let report = DiffReport(catalogs: [diff])
        XCTAssertEqual(report.failures, 1)
    }

    /// Improving a translation is not a defect, and a diff that shouted about
    /// every retranslation would be turned off within a day.
    func testATranslationChangingOnItsOwnIsNotReported() throws {
        let before = catalog(["app.save": localized(["en": "Save", "de": "Speichern"])])
        let after = catalog(["app.save": localized(["en": "Save", "de": "Sichern"])])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertTrue(diff.sourceChanges.isEmpty)
        XCTAssertEqual(DiffReport(catalogs: [diff]).failures, 0)
    }

    /// Xcode marks a translation `needs_review` when it notices the source
    /// move. The catalog is already carrying the warning; repeating it would
    /// make the well-handled case as loud as the broken one.
    func testATranslationAlreadyMarkedForReviewIsNotStale() throws {
        let before = catalog(["app.save": localized(["en": "Save", "de": "Speichern"])])
        let after = catalog([
            "app.save": .object(["localizations": .object([
                "en": unit("Save changes"),
                "de": .object(["stringUnit": .object([
                    "state": .string("needs_review"), "value": .string("Speichern"),
                ])]),
            ])]),
        ])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceChanges.count, 1)
        XCTAssertTrue(try XCTUnwrap(diff.sourceChanges.first).staleLanguages.isEmpty)
        XCTAssertEqual(DiffReport(catalogs: [diff]).failures, 0)
    }

    func testAddedAndRemovedKeysAreAdvisory() throws {
        let before = catalog(["a.gone": localized(["en": "Gone"])])
        let after = catalog(["b.new": localized(["en": "New"])])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.addedKeys, ["b.new"])
        XCTAssertEqual(diff.removedKeys, ["a.gone"])

        let report = DiffReport(catalogs: [diff])
        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.advisories, 2)
    }

    /// A key with no translation at all cannot be stranded by a source change.
    func testAnUntranslatedKeyIsNotStranded() throws {
        let before = catalog(["a.key": localized(["en": "Before"])])
        let after = catalog(["a.key": localized(["en": "After"])])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceChanges.count, 1)
        XCTAssertTrue(try XCTUnwrap(diff.sourceChanges.first).staleLanguages.isEmpty)
    }

    /// A plural key compares on its `other` form, so changing one category is
    /// still a source change.
    func testPluralSourcesAreCompared() throws {
        let before = catalog([
            "count %lld": plural(["one": "%lld item", "other": "%lld items"], de: "%lld Einträge"),
        ])
        let after = catalog([
            "count %lld": plural(["one": "%lld entry", "other": "%lld entries"], de: "%lld Einträge"),
        ])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceChanges.count, 1)
        XCTAssertEqual(try XCTUnwrap(diff.sourceChanges.first).staleLanguages, ["de"])
    }

    /// IceCubesApp's `settings.display.section.platform` is "iPhone", "iPad",
    /// "Mac" and "Apple Vision" at once, under device variations. Reducing it to
    /// one display string picked whichever entry an unordered walk reached
    /// first, so two separately parsed copies of the *same unchanged file*
    /// disagreed — and `diff HEAD~50` reported the heading as having changed
    /// from "iPhone" to "Mac" with five translations stranded. Nothing had
    /// changed at all.
    func testAnUnchangedDeviceVariationKeyIsNotAChange() throws {
        let platform = deviceVariations([
            "iphone": "iPhone", "ipad": "iPad", "mac": "Mac", "applevision": "Apple Vision",
        ])
        let before = catalog(["settings.display.section.platform": platform])
        let after = catalog(["settings.display.section.platform": platform])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertTrue(diff.sourceChanges.isEmpty)
    }

    /// The other half of that fix: a real change to one device case must still
    /// be found, and named, rather than being lost in the reduction.
    func testAChangeInsideOneDeviceVariationIsFound() throws {
        let before = catalog(["a.platform": deviceVariations(["iphone": "iPhone", "mac": "Mac"])])
        let after = catalog(["a.platform": deviceVariations(["iphone": "iPhone", "mac": "Desktop"])])

        let diff = DiffCommand().run(before: before, after: after)
        let change = try XCTUnwrap(diff.sourceChanges.first)
        XCTAssertEqual(change.variation, "device.mac")
        XCTAssertEqual(change.before, "Mac")
        XCTAssertEqual(change.after, "Desktop")
    }

    /// A `shouldTranslate: false` key's translations are not expected to track
    /// the source; flagging them sends someone to write translations the
    /// project has decided not to have.
    func testADoNotTranslateKeyIsNotAStrandedTranslation() throws {
        let entry: (String) -> JSONValue = { english in
            .object([
                "shouldTranslate": .bool(false),
                "localizations": .object([
                    "en": self.unit(english),
                    "de": self.unit("Alte Fassung"),
                ]),
            ])
        }
        let before = catalog(["legal.body": entry("Old text")])
        let after = catalog(["legal.body": entry("New text")])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertTrue(diff.sourceChanges.isEmpty)
    }

    /// Xcode is retiring a stale key; reconciling its translations is work on
    /// a string that is about to be deleted.
    func testAStaleKeyIsNotAStrandedTranslation() throws {
        let entry: (String) -> JSONValue = { english in
            .object([
                "extractionState": .string("stale"),
                "localizations": .object([
                    "en": self.unit(english),
                    "de": self.unit("Alte Fassung"),
                ]),
            ])
        }
        let before = catalog(["old.key": entry("Old text")])
        let after = catalog(["old.key": entry("New text")])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertTrue(diff.sourceChanges.isEmpty)
    }

    /// The words of a pluralised key live *inside* its substitution — the flat
    /// value is just "%#@count@". A rewording there is precisely the change
    /// this command exists to catch, and comparing only the top-level
    /// variations misses it entirely.
    func testASourceChangeInsideASubstitutionIsFound() throws {
        let stringUnit: (String) -> JSONValue = {
            .object(["state": .string("translated"), "value": .string($0)])
        }
        let entry: (String) -> JSONValue = { other in
            .object(["localizations": .object([
                "en": .object([
                    "stringUnit": stringUnit("%#@count@"),
                    "substitutions": .object(["count": .object([
                        "argNum": .number("1"),
                        "formatSpecifier": .string("lld"),
                        "variations": .object(["plural": .object([
                            "one": self.unit("%arg post"),
                            "other": self.unit(other),
                        ])]),
                    ])]),
                ]),
                "de": self.unit("%#@count@"),
            ])])
        }
        let before = catalog(["posts %lld": entry("%arg posts")])
        let after = catalog(["posts %lld": entry("%arg boosts")])

        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceChanges.count, 1)
        let change = try XCTUnwrap(diff.sourceChanges.first)
        XCTAssertEqual(change.variation, "substitutions.count.plural.other")
        XCTAssertEqual(change.before, "%arg posts")
        XCTAssertEqual(change.after, "%arg boosts")
    }

    func testASourceLanguageChangeIsReported() throws {
        let before = try Catalog(
            path: root.appendingPathComponent("a.xcstrings").path,
            sourceLanguage: "en",
            strings: ["a.key": localized(["en": "Text"])]
        )
        let after = try Catalog(
            path: root.appendingPathComponent("a.xcstrings").path,
            sourceLanguage: "de",
            strings: ["a.key": localized(["de": "Text"])]
        )
        let diff = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(diff.sourceLanguageChanged, "en")
    }

    func testLanguagesCanBeNarrowed() throws {
        let before = catalog([
            "a.key": localized(["en": "Before", "de": "Vorher", "ja": "前"]),
        ])
        let after = catalog([
            "a.key": localized(["en": "After", "de": "Vorher", "ja": "前"]),
        ])

        let all = DiffCommand().run(before: before, after: after)
        XCTAssertEqual(try XCTUnwrap(all.sourceChanges.first).staleLanguages, ["de", "ja"])

        let narrowed = DiffCommand(options: .init(languages: ["ja"]))
            .run(before: before, after: after)
        XCTAssertEqual(try XCTUnwrap(narrowed.sourceChanges.first).staleLanguages, ["ja"])
    }

    func testTheFindingCountMatchesTheReportedCounts() throws {
        let before = catalog([
            "a.moved": localized(["en": "Before", "de": "Vorher"]),
            "a.gone": localized(["en": "Gone"]),
        ])
        let after = catalog([
            "a.moved": localized(["en": "After", "de": "Vorher"]),
            "b.new": localized(["en": "New"]),
        ])
        let report = DiffReport(catalogs: [DiffCommand().run(before: before, after: after)])
        XCTAssertEqual(report.findings.count, report.failures + report.advisories)
        XCTAssertEqual(report.findings.filter { $0.level == .error }.count, report.failures)
    }

    // MARK: - Against git

    /// A mistyped ref must fail the run. Without the check it looks like every
    /// catalog is new, which reports nothing wrong at all.
    func testAnUnknownReferenceIsAUsageError() throws {
        try makeRepository()
        let catalog = try Catalog(path: root.appendingPathComponent("App/Localizable.xcstrings").path)
        XCTAssertThrowsError(
            try DiffCommand().run(
                reference: "no-such-ref",
                catalogs: [catalog],
                repositoryRoot: root.path
            )
        )
    }

    func testAGitReferenceIsComparedAgainstTheWorkingTree() throws {
        try makeRepository()
        let path = root.appendingPathComponent("App/Localizable.xcstrings")
        // Change the English and leave the German behind.
        try write(path, strings: [
            "a.title": localized(["en": "Take a bath", "de": "Baden gehen"]),
        ])

        let catalog = try Catalog(path: path.path, displayPath: "App/Localizable.xcstrings")
        let report = try DiffCommand().run(
            reference: "HEAD",
            catalogs: [catalog],
            repositoryRoot: root.path
        )

        XCTAssertEqual(report.catalogs.count, 1)
        let change = try XCTUnwrap(report.catalogs.first?.sourceChanges.first)
        XCTAssertEqual(change.before, "Have a bath")
        XCTAssertEqual(change.after, "Take a bath")
        XCTAssertEqual(change.staleLanguages, ["de"])
        XCTAssertEqual(report.failures, 1)
    }

    /// A catalog added in the commit under review did not exist at the
    /// reference. Every key in it is new, and none of it is an error.
    func testACatalogAbsentAtTheReferenceIsNew() throws {
        try makeRepository()
        let path = root.appendingPathComponent("App/Added.xcstrings")
        try write(path, strings: ["b.key": localized(["en": "Brand new"])])

        let catalog = try Catalog(path: path.path, displayPath: "App/Added.xcstrings")
        let report = try DiffCommand().run(
            reference: "HEAD",
            catalogs: [catalog],
            repositoryRoot: root.path
        )
        XCTAssertTrue(try XCTUnwrap(report.catalogs.first).isNew)
        XCTAssertEqual(try XCTUnwrap(report.catalogs.first).addedKeys, ["b.key"])
        XCTAssertEqual(report.failures, 0)
    }

    /// A catalog inside a nested repository sits under the outer root on disk
    /// but in another history. `git show` fails for its path with the same
    /// message a genuinely new file produces; reporting it as "new" would call
    /// every key an addition and hide any stranded translation in its real
    /// history.
    func testACatalogInANestedRepositoryIsADiagnosticNotANewCatalog() throws {
        try makeRepository()
        let nested = root.appendingPathComponent("Vendored")
        let path = nested.appendingPathComponent("Localizable.xcstrings")
        try write(path, strings: ["v.key": localized(["en": "Vendored"])])
        for arguments in [["init", "-q"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", nested.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("git init failed") }
        }

        let catalog = try Catalog(path: path.path, displayPath: "Vendored/Localizable.xcstrings")
        let report = try DiffCommand().run(
            reference: "HEAD",
            catalogs: [catalog],
            repositoryRoot: root.path
        )
        XCTAssertTrue(report.catalogs.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
        let message = try XCTUnwrap(report.diagnostics.first).message
        XCTAssertTrue(message.contains("nested git repository"), message)
    }

    // MARK: - Helpers

    private func unit(_ value: String) -> JSONValue {
        .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])])
    }

    private func localized(_ values: [String: String]) -> JSONValue {
        .object(["localizations": .object(values.mapValues { unit($0) })])
    }

    /// A key whose English varies by device and has no flat value at all.
    private func deviceVariations(_ cases: [String: String]) -> JSONValue {
        .object(["localizations": .object([
            "en": .object(["variations": .object([
                "device": .object(cases.mapValues { unit($0) }),
            ])]),
        ])])
    }

    private func plural(_ english: [String: String], de: String) -> JSONValue {
        .object(["localizations": .object([
            "en": .object(["variations": .object([
                "plural": .object(english.mapValues { unit($0) }),
            ])]),
            "de": unit(de),
        ])])
    }

    private func catalog(_ strings: [String: JSONValue]) -> Catalog {
        Catalog(
            path: root.appendingPathComponent("App/Localizable.xcstrings").path,
            displayPath: "App/Localizable.xcstrings",
            sourceLanguage: "en",
            strings: strings
        )
    }

    private func write(_ url: URL, strings: [String: JSONValue]) throws {
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
    }

    /// A repository with one committed catalog.
    private func makeRepository() throws {
        try write(root.appendingPathComponent("App/Localizable.xcstrings"), strings: [
            "a.title": localized(["en": "Have a bath", "de": "Baden gehen"]),
        ])
        for arguments in [
            ["init", "-q"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["add", "-A"],
            ["commit", "-q", "-m", "first"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("git \(arguments.joined(separator: " ")) failed")
            }
        }
    }
}
