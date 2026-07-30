import XCTest
import XCLocSmithKit
@testable import xclocsmith

/// The command line itself: flag grammar, dispatch, exit codes, and the JSON
/// shape the README promises agents. Everything else in this suite tests the
/// library; this file tests the layer a user actually types at.
///
/// Two levels, because the contract lives at two levels. Grammar and dispatch
/// are asserted in process against `CommandLineParser` and `Registry`, where a
/// thrown error can be inspected. Exit codes, stderr and the bytes a command
/// does or does not write are asserted against the built binary, because an
/// exit code is not observable from inside the process that would produce it.
final class CLITests: XCTestCase {

    /// Sandbox root. `project` is the working directory commands run in;
    /// `io` holds the pipes, so a snapshot of `project` sees only what the tool
    /// wrote there.
    private var sandbox: URL!
    private var project: URL!
    private var io: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = sandbox.appendingPathComponent("project")
        io = sandbox.appendingPathComponent("io")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: io, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Grammar, in process

    /// The README's command table is a contract: every name in it dispatches,
    /// and `xcloc` is a namespace rather than a command of its own.
    func testEveryDocumentedCommandDispatches() {
        for name in ["check", "scan", "prune", "add", "set", "lookup", "init"] {
            XCTAssertEqual(Registry.command(named: name)?.name, name, name)
        }
        XCTAssertEqual(Registry.xclocAction(named: "check")?.name, "xcloc check")
        XCTAssertEqual(Registry.xclocAction(named: "apply")?.name, "xcloc apply")

        // A namespace, not a command — `xclocsmith xcloc` alone must not run.
        XCTAssertNil(Registry.command(named: "xcloc"))
        XCTAssertNil(Registry.command(named: "frobnicate"))
        // Names are matched exactly; a near miss is an error, not a guess.
        XCTAssertNil(Registry.command(named: "Check"))
        XCTAssertNil(Registry.xclocAction(named: "checks"))
    }

    /// Every flag a command declares must parse, or `--help` advertises
    /// something the parser rejects.
    func testEveryDeclaredFlagIsAccepted() throws {
        for spec in Registry.all {
            for flag in spec.flags {
                let arguments = flag.takesValue ? [flag.name, "value"] : [flag.name]
                let parsed = try CommandLineParser.parse(arguments: arguments, spec: spec)
                if flag.takesValue {
                    XCTAssertEqual(parsed.value(flag), "value", "\(spec.name) \(flag.name)")
                } else {
                    XCTAssertTrue(parsed.isSet(flag), "\(spec.name) \(flag.name)")
                }
            }
        }
    }

    /// The design goal the README states outright: "a flag a command does not
    /// accept is an error, not a no-op". Asserted across the whole cross
    /// product, so adding a flag to one command cannot silently make it
    /// tolerated everywhere.
    func testAFlagIsRejectedByEveryCommandThatDoesNotDeclareIt() {
        let everyFlag = Registry.all.flatMap(\.flags)
        for spec in Registry.all {
            let declared = Set(spec.flags.map(\.name))
            for flag in everyFlag where !declared.contains(flag.name) {
                let arguments = flag.takesValue ? [flag.name, "value"] : [flag.name]
                XCTAssertThrowsError(
                    try CommandLineParser.parse(arguments: arguments, spec: spec),
                    "\(spec.name) accepted \(flag.name)"
                ) { error in
                    guard case SmithError.usage(let message) = error else {
                        return XCTFail("\(spec.name) \(flag.name): \(error)")
                    }
                    // A flag that exists elsewhere gets a different sentence from
                    // one that exists nowhere: the fixes are different.
                    XCTAssertTrue(
                        message.contains("\(flag.name) is not accepted by `\(spec.name)`"),
                        message
                    )
                    XCTAssertTrue(message.contains("Run `xclocsmith \(spec.name) --help`"), message)
                }
            }
        }
    }

    /// A misspelling is not a flag of some other command, and must say so
    /// rather than implying the user picked the wrong subcommand.
    func testAnUnknownFlagIsDistinguishedFromAMisplacedOne() {
        XCTAssertThrowsError(try CommandLineParser.parse(arguments: ["--frobnicate"], spec: Registry.check)) { error in
            guard case SmithError.usage(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("unknown option --frobnicate"), message)
            // The accepted set is listed, so the fix does not need a second run.
            XCTAssertTrue(message.contains("--lang"), message)
        }
    }

    /// `--lang` with nothing after it must fail, not consume the next word.
    /// Silently taking a following argument is how `check --lang` ends up
    /// checking a language named after a file path.
    func testAValueFlagWithNoValueIsAUsageError() {
        XCTAssertThrowsError(try CommandLineParser.parse(arguments: ["--lang"], spec: Registry.check)) { error in
            XCTAssertEqual(error as? SmithError, .usage("--lang needs a value"))
        }
        // Also at the end of a longer line, where the mistake is easier to make.
        XCTAssertThrowsError(
            try CommandLineParser.parse(arguments: ["--json", "--out"], spec: Registry.check)
        ) { error in
            XCTAssertEqual(error as? SmithError, .usage("--out needs a value"))
        }
    }

    /// `--json=yes` is a user who thinks `--json` is a switch with settings.
    /// Accepting it and discarding "yes" would teach the wrong grammar.
    func testABooleanFlagRejectsAnInlineValue() {
        XCTAssertThrowsError(try CommandLineParser.parse(arguments: ["--json=yes"], spec: Registry.check)) { error in
            XCTAssertEqual(error as? SmithError, .usage("--json does not take a value"))
        }
    }

    /// `--lang=ja` and `--lang ja` are the same request, and repeated or
    /// comma-separated languages accumulate rather than overwrite.
    func testValueFlagsAccumulateAcrossBothSpellings() throws {
        let inline = try CommandLineParser.parse(arguments: ["--lang=ja"], spec: Registry.check)
        let separate = try CommandLineParser.parse(arguments: ["--lang", "ja"], spec: Registry.check)
        XCTAssertEqual(CommandLineParser.languages(inline), ["ja"])
        XCTAssertEqual(CommandLineParser.languages(separate), ["ja"])

        let many = try CommandLineParser.parse(
            arguments: ["--lang", "ja, de", "--lang=fr"],
            spec: Registry.check
        )
        XCTAssertEqual(CommandLineParser.languages(many), ["ja", "de", "fr"])
    }

    /// `--` ends flag parsing, and what follows is a word rather than a path.
    /// A key that looks like a flag, and a key that looks like a catalog, both
    /// have to survive it — that is the whole point of the separator.
    func testSeparatorEndsFlagParsing() throws {
        let parsed = try CommandLineParser.parse(
            arguments: ["--lang", "ja", "--", "--odd key", "App/Localizable.xcstrings"],
            spec: Registry.set
        )
        XCTAssertEqual(CommandLineParser.languages(parsed), ["ja"])
        XCTAssertEqual(parsed.positionals, ["--odd key", "App/Localizable.xcstrings"])
        // Neither positional may be re-read as a catalog path.
        XCTAssertTrue(parsed.classifiablePositionals.isEmpty)
    }

    /// A bare `-` is `add`'s stdin sentinel, not a malformed flag.
    func testLoneDashIsAPositional() throws {
        let parsed = try CommandLineParser.parse(arguments: ["-"], spec: Registry.add)
        XCTAssertEqual(parsed.positionals, ["-"])
    }

    /// `xclocsmith <command> --help` must list exactly the flags that command
    /// accepts — no more, since anything else it names is a flag the parser
    /// will refuse.
    func testCommandHelpListsExactlyTheAcceptedFlags() throws {
        for spec in Registry.all {
            let help = Help.command(spec)
            let options = try XCTUnwrap(help.components(separatedBy: "Options:").last, spec.name)
            for flag in spec.flags {
                XCTAssertTrue(options.contains(flag.name), "\(spec.name) help omits \(flag.name)")
            }
            let declared = Set(spec.flags.map(\.name))
            for name in Registry.allFlags where !declared.contains(name) {
                XCTAssertFalse(options.contains(name), "\(spec.name) help advertises \(name)")
            }
            XCTAssertTrue(help.contains(spec.usage), spec.name)
        }
    }

    /// The global help is the only place the exit-code convention is written
    /// down for someone who never opens the README.
    func testGlobalHelpNamesEveryCommandAndTheExitCodes() {
        let help = Help.global()
        for spec in Registry.all {
            XCTAssertTrue(help.contains(spec.name), "global help omits \(spec.name)")
        }
        XCTAssertTrue(help.contains("Exit codes: 0 clean, 1 findings, 2 usage or I/O error."), help)
    }

    // MARK: - Exit codes and dispatch, out of process

    /// The convention every CI snippet in the README depends on: 0 clean,
    /// 1 findings, 2 usage or I/O error.
    func testExitCodesFollowTheDocumentedConvention() throws {
        try makeProject()

        // Everything translated: clean.
        XCTAssertEqual(try xclocsmith(["check"]).status, 0)
        // One string in source that no catalog carries: a finding.
        XCTAssertEqual(try xclocsmith(["scan"]).status, 1)
        // A flag this command does not take: neither clean nor a finding.
        XCTAssertEqual(try xclocsmith(["check", "--apply"]).status, 2)
    }

    /// An unknown command must name itself and point at `--help`, and must not
    /// reach the Swift runtime's error path — a stack trace is never a usage
    /// message.
    func testUnknownCommandFailsCleanly() throws {
        try makeProject()
        let run = try xclocsmith(["frobnicate"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains(#"unknown command "frobnicate""#), run.error)
        XCTAssertTrue(run.error.contains("xclocsmith --help"), run.error)
        assertNoCrash(run)
    }

    /// `xcloc` is a namespace: a bad action names the ones that exist, and the
    /// bare namespace prints its own usage rather than dispatching to nothing.
    func testXclocNamespaceRejectsBadActions() throws {
        try makeProject()

        let bogus = try xclocsmith(["xcloc", "bogus", "ja.xliff"])
        XCTAssertEqual(bogus.status, 2)
        XCTAssertTrue(bogus.error.contains(#"unknown xcloc action "bogus""#), bogus.error)
        XCTAssertTrue(bogus.error.contains("check, apply"), bogus.error)
        assertNoCrash(bogus)

        let bare = try xclocsmith(["xcloc"])
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.output.contains("Usage: xclocsmith xcloc <check|apply>"), bare.output)
    }

    /// Help is a successful outcome under every spelling; no arguments at all
    /// is a usage error that still shows the help.
    func testRootHelpAndVersion() throws {
        try makeProject()

        for spelling in ["--help", "-h", "help"] {
            let run = try xclocsmith([spelling])
            XCTAssertEqual(run.status, 0, spelling)
            XCTAssertTrue(run.output.contains("Usage: xclocsmith <command> [options]"), spelling)
        }
        for spelling in ["--version", "-v"] {
            let run = try xclocsmith([spelling])
            XCTAssertEqual(run.status, 0, spelling)
            XCTAssertFalse(run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, spelling)
        }

        let bare = try xclocsmith([])
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.output.contains("Usage: xclocsmith <command>"), bare.output)
    }

    /// Every command answers `--help` and `-h` with its own page and exit 0,
    /// including the two-word `xcloc` actions, where the flag arrives after
    /// two words rather than one.
    func testEverySubcommandAnswersHelp() throws {
        try makeProject()
        for spec in Registry.all {
            let words = spec.name.split(separator: " ").map(String.init)
            for spelling in ["--help", "-h"] {
                let run = try xclocsmith(words + [spelling])
                XCTAssertEqual(run.status, 0, "\(spec.name) \(spelling)")
                XCTAssertTrue(run.output.contains(spec.usage), "\(spec.name) \(spelling): \(run.output)")
                assertNoCrash(run)
            }
        }
    }

    /// The rejection is a real error on stderr with a real exit code, not a
    /// warning printed on the way to doing the work anyway.
    func testAMisplacedFlagIsRejectedByTheBinary() throws {
        try makeProject()

        let run = try xclocsmith(["check", "--dry-run"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains("--dry-run is not accepted by `check`"), run.error)
        XCTAssertTrue(run.error.contains("check accepts:"), run.error)
        // Nothing was reported, because nothing ran.
        XCTAssertTrue(run.output.isEmpty, run.output)

        // The converse: a reading flag on a writing command.
        let prune = try xclocsmith(["prune", "--lang", "ja"])
        XCTAssertEqual(prune.status, 2)
        XCTAssertTrue(prune.error.contains("--lang is not accepted by `prune`"), prune.error)
    }

    /// Contradictory intent is a question, not a default. Picking either one
    /// silently would make `--dry-run --apply` write or not write depending on
    /// argument order.
    func testContradictoryWriteFlagsAreRejected() throws {
        try makeProject()
        let run = try xclocsmith(["prune", "--dry-run", "--apply"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains("--dry-run and --apply contradict each other"), run.error)
    }

    // MARK: - Bad input

    /// A config path that does not exist is a misconfiguration, and must be
    /// louder than a finding — the README's CI snippet branches on exactly this.
    func testMissingConfigFileIsAClearError() throws {
        try makeProject()
        let run = try xclocsmith(["check", "--config", sandbox.appendingPathComponent("nope.json").path])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains("cannot read"), run.error)
        XCTAssertTrue(run.error.contains("nope.json"), run.error)
        assertNoCrash(run)
    }

    /// Run in a directory with no catalogs anywhere and the answer is "this is
    /// not a project", not "zero findings, clean".
    func testProjectWithNoCatalogsIsAnErrorNotACleanRun() throws {
        let empty = sandbox.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let run = try xclocsmith(["check"], in: empty)
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains("no .xcstrings catalogs found"), run.error)
        assertNoCrash(run)
    }

    /// An unparseable catalog is reported as a diagnostic on the run rather
    /// than throwing away the report — but it still fails, so a corrupt file
    /// cannot pass CI by being unreadable.
    func testUnreadableCatalogIsReportedNotCrashed() throws {
        try makeProject()
        let broken = project.appendingPathComponent("App/Broken.xcstrings")
        try "{ this is not json".write(to: broken, atomically: true, encoding: .utf8)

        let run = try xclocsmith(["check", "App/Broken.xcstrings", "--json"])
        XCTAssertEqual(run.status, 1)
        assertNoCrash(run)

        let json = try jsonObject(run.output)
        let diagnostics = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0]["path"] as? String, "App/Broken.xcstrings")
    }

    /// A language the catalog has never seen is a typo, and a typo that
    /// "checks nothing successfully" is the failure mode the exit-code split
    /// exists to prevent.
    func testUnknownLanguageFailsTheRunRatherThanCheckingNothing() throws {
        try makeProject()
        let run = try xclocsmith(["check", "--lang", "zz"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains(#""zz" is not a language"#), run.error)
    }

    /// Values that are validated as well as parsed: an out-of-range threshold
    /// and an invented translation state both name the accepted range.
    func testOutOfRangeFlagValuesAreRejectedWithTheirRange() throws {
        try makeProject()

        let threshold = try xclocsmith(["check", "--threshold", "999"])
        XCTAssertEqual(threshold.status, 2)
        XCTAssertTrue(threshold.error.contains("between 50 and 99"), threshold.error)

        let state = try xclocsmith(["set", "--lang", "ja", "--state", "bogus", "Save", "x"])
        XCTAssertEqual(state.status, 2)
        XCTAssertTrue(state.error.contains("is not a string-unit state"), state.error)
    }

    /// A payload path that does not exist must say which file, since `add`
    /// takes its path positionally and a typo is otherwise invisible.
    func testMissingPayloadIsAClearError() throws {
        try makeProject()
        let run = try xclocsmith(["add", "nope.json"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.error.contains("cannot read nope.json"), run.error)
        assertNoCrash(run)
    }

    // MARK: - JSON

    /// `--json` must put nothing but JSON on stdout, or the `| jq` pipelines in
    /// the README break the first time a command has something to say.
    func testJSONOutputIsTheOnlyThingOnStdout() throws {
        try makeProject()
        for arguments in [["check", "--json"], ["scan", "--json"], ["prune", "--json"], ["lookup", "Save", "--json"]] {
            let run = try xclocsmith(arguments)
            XCTAssertNoThrow(try jsonObject(run.output), "\(arguments): \(run.output)")
        }
    }

    /// The keys the README documents for each report, including the exact
    /// fields its `jq` example selects from `scan`.
    func testJSONCarriesTheDocumentedShape() throws {
        try makeProject()

        let check = try jsonObject(try xclocsmith(["check", "--json"]).output)
        XCTAssertEqual(check["command"] as? String, "check")
        for key in ["catalogs", "diagnostics", "templatesWritten", "failures", "advisories"] {
            XCTAssertNotNil(check[key], "check --json has no \(key)")
        }

        let scan = try jsonObject(try xclocsmith(["scan", "--json"]).output)
        XCTAssertEqual(scan["command"] as? String, "scan")
        let missing = try XCTUnwrap(scan["missingKeys"] as? [[String: Any]])
        let finding = try XCTUnwrap(missing.first)
        for key in ["value", "file", "line", "catalog"] {   // README's jq example
            XCTAssertNotNil(finding[key], "missingKeys entry has no \(key)")
        }
        XCTAssertEqual(finding["value"] as? String, "Not in catalog")

        let prune = try jsonObject(try xclocsmith(["prune", "--json"]).output)
        XCTAssertEqual(prune["command"] as? String, "prune")
        XCTAssertNotNil(prune["catalogs"])
        XCTAssertNotNil(prune["failures"])
    }

    /// "`failures` always equals the number of findings enumerated in the
    /// payload": an agent that fixes every entry it can see reaches exit 0.
    func testJSONFailureCountMatchesTheEnumeratedFindings() throws {
        try makeProject()
        let run = try xclocsmith(["scan", "--json"])
        XCTAssertEqual(run.status, 1)

        let json = try jsonObject(run.output)
        let enumerated = ["missingKeys", "untranslated", "diagnostics"]
            .compactMap { json[$0] as? [Any] }
            .reduce(0) { $0 + $1.count }
        XCTAssertEqual(json["failures"] as? Int, enumerated)
    }

    // MARK: - Writing, and not writing

    /// `prune` reports by default. Asserted on the file's bytes rather than on
    /// its parsed contents, because "rewrote it identically" is still a diff in
    /// someone's working tree.
    func testPruneWritesNothingWithoutApply() throws {
        // One dead key in eight, which stays under the quarter-of-a-catalog
        // guard that `testPruneRefusalExitsAsAnErrorAndWritesNothing` trips.
        var keys = ["Dead key": "死"]
        for word in ["Save", "Cancel", "Delete", "Edit", "Close", "Open", "Retry"] { keys[word] = "訳" }
        try makeProject(catalogKeys: keys)
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: catalog)

        let dry = try xclocsmith(["prune"])
        XCTAssertEqual(dry.status, 0)
        XCTAssertTrue(dry.output.contains("Re-run with --apply"), dry.output)
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        let applied = try xclocsmith(["prune", "--apply"])
        XCTAssertEqual(applied.status, 0)
        XCTAssertNotEqual(try Data(contentsOf: catalog), before)

        let after = try Catalog(path: catalog.path)
        XCTAssertNil(after.strings["Dead key"])
        XCTAssertNotNil(after.strings["Save"])
    }

    /// A refusal exits 2, not 1: it needs a decision about the configuration,
    /// and a CI job that treats it as "findings" will keep retrying a fix that
    /// cannot work.
    func testPruneRefusalExitsAsAnErrorAndWritesNothing() throws {
        // Almost the whole catalog is unreferenced, which trips the ratio guard.
        var keys = ["Save": "保存"]
        for index in 0..<20 { keys["Dead \(index)"] = "死\(index)" }
        try makeProject(catalogKeys: keys)
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: catalog)

        let run = try xclocsmith(["prune", "--apply"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.output.contains("pass --force"), run.output)
        XCTAssertEqual(try Data(contentsOf: catalog), before)
    }

    /// `add` and `set` are the write commands: they write by default, and
    /// `--dry-run` genuinely previews. A `--dry-run` that wrote anyway would be
    /// worse than no `--dry-run` at all.
    func testAddAndSetWriteByDefaultAndDryRunDoesNot() throws {
        try makeProject()
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: catalog)

        let previewed = try xclocsmith(["set", "--lang", "ja", "--dry-run", "Save", "保存する"])
        XCTAssertEqual(previewed.status, 0)
        XCTAssertTrue(previewed.output.contains("dry run"), previewed.output)
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        let written = try xclocsmith(["set", "--lang", "ja", "Save", "保存する"])
        XCTAssertEqual(written.status, 0)
        XCTAssertEqual(try Catalog(path: catalog.path).value("Save", "ja"), "保存する")

        // `add` reads its payload from stdin when the path is `-`.
        let reverted = try Data(contentsOf: catalog)
        let payload = """
            {"format":"xclocsmith/v1","catalog":"App/Localizable.xcstrings",\
            "language":"ja","strings":{"Save":"セーブ"}}
            """
        let dryAdd = try xclocsmith(["add", "-", "--dry-run"], stdin: payload)
        XCTAssertEqual(dryAdd.status, 0)
        XCTAssertEqual(try Data(contentsOf: catalog), reverted)

        let realAdd = try xclocsmith(["add", "-"], stdin: payload)
        XCTAssertEqual(realAdd.status, 0)
        XCTAssertEqual(try Catalog(path: catalog.path).value("Save", "ja"), "セーブ")
    }

    /// `xcloc apply` is an import, so it reports before it writes for the same
    /// reason `prune` does.
    func testXclocApplyReportsBeforeItWrites() throws {
        try makeProject()
        try writeXLIFF()
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: catalog)

        let dry = try xclocsmith(["xcloc", "apply", "ja.xliff"])
        XCTAssertEqual(dry.status, 0)
        XCTAssertTrue(dry.output.contains("Re-run with --apply"), dry.output)
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        let applied = try xclocsmith(["xcloc", "apply", "ja.xliff", "--apply"])
        XCTAssertEqual(applied.status, 0)
        XCTAssertEqual(try Catalog(path: catalog.path).value("Save", "ja"), "セーブ")
    }

    /// `xcloc check` reads only, whatever it finds.
    func testXclocCheckWritesNothing() throws {
        try makeProject()
        try writeXLIFF()
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: catalog)

        let run = try xclocsmith(["xcloc", "check", "ja.xliff"])
        assertNoCrash(run)
        XCTAssertEqual(try Data(contentsOf: catalog), before)
    }

    /// `scan` and `check` leave the work tree alone unless asked, so a repo
    /// with a clean-tree check in CI can run them.
    func testReadingCommandsLeaveTheTreeAloneUnlessAsked() throws {
        try makeProject()
        let before = try snapshot()

        XCTAssertEqual(try xclocsmith(["scan"]).status, 1)
        XCTAssertEqual(try xclocsmith(["check"]).status, 0)
        XCTAssertEqual(try snapshot(), before)

        // `--out` is the opt in, and it writes exactly one file.
        XCTAssertEqual(try xclocsmith(["scan", "--out", "work.json"]).status, 1)
        XCTAssertEqual(try snapshot().subtracting(before), ["work.json"])
    }

    /// The regression this file was written after: `--` ends flag parsing, so
    /// `set -- "--help" "値"` must set a key named `--help` rather than print
    /// the help page and exit 0 having written nothing.
    func testSeparatorSurvivesKeysThatLookLikeHelpFlags() throws {
        try makeProject()
        let catalog = project.appendingPathComponent("App/Localizable.xcstrings")

        let run = try xclocsmith(["set", "--lang", "ja", "--create", "--", "--help", "値"])
        XCTAssertEqual(run.status, 0)
        XCTAssertFalse(run.output.contains("Usage: xclocsmith set"), run.output)
        XCTAssertEqual(try Catalog(path: catalog.path).value("--help", "ja"), "値")

        // `-h` too, and as a lookup query rather than a request for help.
        let lookup = try xclocsmith(["lookup", "--", "-h"])
        XCTAssertFalse(lookup.output.contains("Usage: xclocsmith lookup"), lookup.output)
    }

    // MARK: - Remaining commands

    /// `lookup` exits 1 when nothing matched, so a script can gate on it.
    func testLookupExitsOneWhenNothingMatched() throws {
        try makeProject()
        XCTAssertEqual(try xclocsmith(["lookup", "Save"]).status, 0)
        XCTAssertEqual(try xclocsmith(["lookup", "nothing remotely like this"]).status, 1)
    }

    /// `init` refuses to overwrite an existing configuration, because the file
    /// it would replace is hand-edited by definition.
    func testInitWritesOnceAndRefusesToOverwrite() throws {
        try makeProject(configuration: false)

        let first = try xclocsmith(["init"])
        XCTAssertEqual(first.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(Configuration.fileName).path
        ))

        let second = try xclocsmith(["init"])
        XCTAssertEqual(second.status, 2)
        XCTAssertTrue(second.error.contains("already exists (pass --force"), second.error)

        XCTAssertEqual(try xclocsmith(["init", "--force"]).status, 0)
    }

    // MARK: - Fixtures

    /// A minimal project: one target, one catalog, one referenced key that is
    /// translated, one key nothing references, and one string in source that no
    /// catalog carries. Enough for `check` to be clean while `scan` finds
    /// something and `prune` has a candidate.
    private func makeProject(
        catalogKeys: [String: String]? = nil,
        configuration writeConfiguration: Bool = true
    ) throws {
        let app = project.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let keys = catalogKeys ?? ["Save": "保存", "Dead key": "死"]
        var referenced = keys.keys.sorted()
        referenced.removeAll { $0.hasPrefix("Dead") }
        let calls = (referenced + ["Not in catalog"]).map { #"    Text("\#($0)")"# }
        try """
            import SwiftUI
            struct V: View {
                var body: some View {
            \(calls.joined(separator: "\n"))
                }
            }
            """.write(to: app.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)

        var strings: [String: JSONValue] = [:]
        for (key, value) in keys {
            strings[key] = .object(["localizations": .object([
                "ja": .object(["stringUnit": .object([
                    "state": .string("translated"), "value": .string(value),
                ])]),
            ])])
        }
        let document = JSONValue.object([
            "sourceLanguage": .string("en"),
            "version": .string("1.0"),
            "strings": .object(strings),
        ])
        try JSONWriter.text(document).write(
            to: app.appendingPathComponent("Localizable.xcstrings"),
            atomically: true,
            encoding: .utf8
        )

        guard writeConfiguration else { return }
        try """
            {
              "targets": [
                {
                  "name": "App",
                  "sources": ["App"],
                  "catalogs": ["App/Localizable.xcstrings"]
                }
              ],
              "languages": ["ja"]
            }
            """.write(
                to: project.appendingPathComponent(Configuration.fileName),
                atomically: true,
                encoding: .utf8
            )
    }

    /// A bare `.xliff`, which is what localizers usually return, translating a
    /// key the fixture catalog already has.
    private func writeXLIFF() throws {
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2">
              <file original="App/Localizable.strings" source-language="en" target-language="ja" datatype="plaintext">
                <body>
                  <trans-unit id="Save" xml:space="preserve">
                    <source>Save</source>
                    <target state="translated">セーブ</target>
                  </trans-unit>
                </body>
              </file>
            </xliff>
            """.write(to: project.appendingPathComponent("ja.xliff"), atomically: true, encoding: .utf8)
    }

    /// Every path under the project, so a test can assert a command added
    /// nothing rather than only that it added no catalog.
    private func snapshot() throws -> Set<String> {
        let enumerator = FileManager.default.enumerator(atPath: project.path)
        return Set((enumerator?.allObjects as? [String]) ?? [])
    }

    // MARK: - Running the binary

    private struct Invocation {
        let status: Int32
        let reason: Process.TerminationReason
        let output: String
        let error: String
    }

    /// The executable is linked into the same directory as the test bundle, so
    /// it is resolved from there. Shelling out to `swift build --show-bin-path`
    /// would block on the package lock this very test session holds.
    private static let binary: URL = Bundle(for: CLITests.self)
        .bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("xclocsmith")

    @discardableResult
    private func xclocsmith(
        _ arguments: [String],
        in directory: URL? = nil,
        stdin: String? = nil
    ) throws -> Invocation {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.binary.path),
            "xclocsmith was not built next to the test bundle at \(Self.binary.path)"
        )

        // Redirected to files rather than pipes: two pipes read in sequence
        // deadlock as soon as the second one fills its buffer.
        let outPath = io.appendingPathComponent(UUID().uuidString)
        let errPath = io.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outPath.path, contents: nil)
        FileManager.default.createFile(atPath: errPath.path, contents: nil)

        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? project
        process.standardOutput = try FileHandle(forWritingTo: outPath)
        process.standardError = try FileHandle(forWritingTo: errPath)
        if let stdin {
            let inPath = io.appendingPathComponent(UUID().uuidString)
            try Data(stdin.utf8).write(to: inPath)
            process.standardInput = try FileHandle(forReadingFrom: inPath)
        }
        try process.run()
        process.waitUntilExit()

        return Invocation(
            status: process.terminationStatus,
            reason: process.terminationReason,
            output: (try? String(contentsOf: outPath, encoding: .utf8)) ?? "",
            error: (try? String(contentsOf: errPath, encoding: .utf8)) ?? ""
        )
    }

    /// Bad input is a message, never a trap. A stack trace on stderr is a bug
    /// report the user cannot act on.
    private func assertNoCrash(_ run: Invocation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.reason, .exit, "terminated by signal", file: file, line: line)
        for marker in ["Fatal error", "Stack dump", "Current stack trace", "Illegal instruction"] {
            XCTAssertFalse(run.error.contains(marker), "\(marker) in stderr:\n\(run.error)", file: file, line: line)
        }
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String: Any])
    }
}
