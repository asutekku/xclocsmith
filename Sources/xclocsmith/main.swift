import Foundation
import XCLocSmithKit

// Exit codes: 0 clean, 1 findings, 2 usage or I/O error.
let exitClean: Int32 = 0
let exitFindings: Int32 = 1
let exitError: Int32 = 2

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("xclocsmith: " + message + "\n").utf8))
}

func emit(
    _ report: some Report,
    format: OutputFormat,
    configuration: Configuration,
    text: @autoclosure () -> String,
    strict: Bool
) -> Int32 {
    switch format {
    case .text:
        print(text())
    case .json:
        print(JSONWriter.text(report.jsonValue, style: .plain), terminator: "")
    case .sarif:
        let renderer = MachineRenderer(configuration: configuration)
        print(renderer.sarif(report, toolVersion: toolVersion), terminator: "")
    case .github:
        // A clean run prints nothing at all: a workflow log with one blank line
        // in it reads as output that failed to happen.
        let output = MachineRenderer(configuration: configuration).github(report)
        if !output.isEmpty { print(output) }
    }
    if report.failures > 0 { return exitFindings }
    if strict && report.advisories > 0 { return exitFindings }
    return exitClean
}

func emit(_ report: some Report, json: Bool, text: @autoclosure () -> String, strict: Bool) -> Int32 {
    emit(
        report,
        format: json ? .json : .text,
        configuration: Configuration(root: FileManager.default.currentDirectoryPath),
        text: text(),
        strict: strict
    )
}

func makeConfiguration(_ parsed: ParsedCommand) throws -> Configuration {
    var configuration = try Configuration.load(
        explicitPath: parsed.value(Flags.config),
        useConfigFile: !parsed.isSet(Flags.noConfig),
        workingDirectory: FileManager.default.currentDirectoryPath
    )
    if let raw = parsed.value(Flags.threshold) {
        guard let threshold = Int(raw), (50...99).contains(threshold) else {
            throw SmithError.usage("--threshold takes a whole number between 50 and 99")
        }
        configuration.similarityThreshold = threshold
    }
    if parsed.isSet(Flags.previews) { configuration.scanPreviews = true }
    return configuration
}

func translationState(_ parsed: ParsedCommand) throws -> TranslationState {
    guard let raw = parsed.value(Flags.state) else { return .translated }
    guard let state = TranslationState(rawValue: raw) else { throw SmithError.invalidState(raw) }
    return state
}

func catalogArguments(_ parsed: ParsedCommand) -> [String] {
    parsed.classifiablePositionals.filter { $0.hasSuffix(".xcstrings") }
}

/// Positionals a command reads as words rather than paths.
func wordArguments(_ parsed: ParsedCommand) -> [String] {
    let catalogs = Set(catalogArguments(parsed))
    return parsed.positionals.filter { !catalogs.contains($0) }
}

func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())

    guard let first = arguments.first else {
        print(Help.global())
        return exitError
    }
    if first == "--help" || first == "-h" || first == "help" {
        print(Help.global())
        return exitClean
    }
    if first == "--version" || first == "-v" {
        print(toolVersion)
        return exitClean
    }
    var spec: CommandSpec
    var rest: [String]

    if first == "xcloc" {
        let actions = Registry.xclocActions.map { $0.name.replacingOccurrences(of: "xcloc ", with: "") }
        guard let action = arguments.dropFirst().first, !action.hasPrefix("-") else {
            print("Usage: xclocsmith xcloc <\(actions.joined(separator: "|"))> <bundle.xcloc|file.xliff>")
            for command in Registry.xclocActions {
                print("  \(command.name.replacingOccurrences(of: "xcloc ", with: ""))  \(command.summary)")
            }
            return exitError
        }
        guard let resolved = Registry.xclocAction(named: action) else {
            printError("unknown xcloc action \"\(action)\" (expected: \(actions.joined(separator: ", ")))")
            return exitError
        }
        spec = resolved
        rest = Array(arguments.dropFirst(2))
    } else {
        guard let resolved = Registry.command(named: first) else {
            printError("unknown command \"\(first)\". Run `xclocsmith --help`.")
            return exitError
        }
        spec = resolved
        rest = Array(arguments.dropFirst())
    }
    // Only words before `--` are flags. Scanning all of `rest` would make
    // `set -- "--help" "値"` print help instead of writing the key, which is
    // exactly the case `--` exists to allow.
    if rest.prefix(while: { $0 != "--" }).contains(where: { $0 == "--help" || $0 == "-h" }) {
        print(Help.command(spec))
        return exitClean
    }

    do {
        let parsed = try CommandLineParser.parse(arguments: rest, spec: spec)
        let renderer = TextRenderer()
        let json = parsed.isSet(Flags.json)
        let strict = parsed.isSet(Flags.strict)
        // Resolved before anything runs. Validating it at the point of printing
        // means a misspelled --format does the entire scan first and then
        // refuses to show you the answer.
        let format = spec.flag(named: Flags.format.name) == nil
            ? (json ? OutputFormat.json : .text)
            : try CommandLineParser.format(parsed)

        switch spec.name {
        case "check":
            let configuration = try makeConfiguration(parsed)
            let command = CheckCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    templatePath: parsed.value(Flags.out)
                )
            )
            let catalogs = catalogArguments(parsed)
            let report = try command.run(catalogPaths: catalogs.isEmpty ? nil : catalogs)
            return emit(
                report,
                format: format,
                configuration: configuration,
                text: renderer.render(report),
                strict: strict
            )

        case "scan":
            var configuration = try makeConfiguration(parsed)
            let directories = wordArguments(parsed)
            if !directories.isEmpty {
                configuration.targets = configuration.targets.map {
                    Target(name: $0.name, sources: directories, referenceSources: [], catalogs: $0.catalogs)
                }
            }
            // Writing files is opt-in: a scan that litters the work tree breaks
            // any pipeline with a clean-tree check.
            let wantsTemplate = parsed.isSet(Flags.template) || parsed.value(Flags.out) != nil
            let command = ScanCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    writeTemplates: wantsTemplate && !parsed.isSet(Flags.noTemplate),
                    templatePath: parsed.value(Flags.out),
                    includeFormatKeysInOrphans: parsed.isSet(Flags.includeFormatKeys),
                    files: CommandLineParser.files(parsed)
                )
            )
            let report = try command.run()
            return emit(
                report,
                format: format,
                configuration: configuration,
                text: renderer.render(report),
                strict: strict
            )

        case "diff":
            let configuration = try makeConfiguration(parsed)
            // `--lang all` means every language either side has, which is
            // already what an empty list means here. Passing "all" through
            // would compare a language literally named "all" and find nothing.
            let requested = CommandLineParser.languages(parsed)
            let languages = requested.contains("all") ? [] : requested
            let command = DiffCommand(options: .init(languages: languages))
            let paths = catalogArguments(parsed)
            let report: DiffReport
            if paths.count == 2 {
                // Two files, no git: the form that works on an export, a
                // backup, or anything not in a repository at all.
                let before = try Catalog(path: configuration.absolute(paths[0]))
                let after = try Catalog(
                    path: configuration.absolute(paths[1]),
                    displayPath: paths[1]
                )
                report = DiffReport(catalogs: [command.run(before: before, after: after)])
            } else if paths.count == 1 {
                throw SmithError.usage(
                    "diff takes a git ref, or two catalog paths. One path is neither."
                )
            } else {
                let words = wordArguments(parsed)
                guard words.count == 1 else { throw SmithError.usage("usage: \(spec.usage)") }
                let workspace = Workspace(configuration: configuration)
                // A misspelled --lang must fail the run rather than compare
                // nothing and report clean, which is the failure mode this tool
                // exists to complain about in other people's tooling.
                for catalog in workspace.allCatalogs() {
                    _ = try workspace.languages(for: catalog, requested: requested)
                }
                guard let root = Git.repositoryRoot(of: configuration.root) else {
                    throw SmithError.usage("\(configuration.root) is not inside a git repository")
                }
                report = try command.run(
                    reference: words[0],
                    catalogs: workspace.allCatalogs(),
                    repositoryRoot: root
                )
            }
            return emit(
                report,
                format: format,
                configuration: configuration,
                text: renderer.render(report),
                strict: strict
            )

        case "prune":
            let configuration = try makeConfiguration(parsed)
            if parsed.isSet(Flags.dryRun) && parsed.isSet(Flags.apply) {
                throw SmithError.usage("--dry-run and --apply contradict each other")
            }
            let command = PruneCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    dryRun: !parsed.isSet(Flags.apply),
                    force: parsed.isSet(Flags.force),
                    includeFormatKeys: parsed.isSet(Flags.includeFormatKeys)
                )
            )
            let report = WriteReports(command: "prune", reports: try command.run())
            if json {
                print(JSONWriter.text(report.jsonValue, style: .plain), terminator: "")
            } else {
                print(report.reports.map(renderer.render).joined(separator: "\n"))
                if !parsed.isSet(Flags.apply) {
                    print("Nothing was written. Re-run with --apply to remove these keys.")
                }
            }
            // A refusal means the run needs a decision, not that findings exist.
            return report.failures > 0 ? exitError : exitClean

        case "add":
            let configuration = try makeConfiguration(parsed)
            guard let payloadPath = parsed.positionals.first(where: { $0.hasSuffix(".json") || $0 == "-" }) else {
                throw SmithError.usage("usage: \(spec.usage)")
            }
            let data: Data
            if payloadPath == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                guard let contents = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)) else {
                    throw SmithError.cannotRead(path: payloadPath, reason: "unreadable")
                }
                data = contents
            }
            let payload = try TranslationPayload.load(from: data, path: payloadPath)
            let command = AddCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    state: try translationState(parsed),
                    flatten: parsed.isSet(Flags.flatten),
                    dryRun: parsed.isSet(Flags.dryRun),
                    allowNewLanguage: parsed.isSet(Flags.addLanguage)
                )
            )
            let report = try command.run(payload: payload, catalogPath: catalogArguments(parsed).first)
            return emit(report, json: json, text: renderer.render(report), strict: strict)

        case "set":
            let configuration = try makeConfiguration(parsed)
            let words = wordArguments(parsed)
            guard words.count == 2 else {
                throw SmithError.usage("usage: \(spec.usage)")
            }
            let command = SetCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    state: try translationState(parsed),
                    flatten: parsed.isSet(Flags.flatten),
                    dryRun: parsed.isSet(Flags.dryRun),
                    allowNewLanguage: parsed.isSet(Flags.addLanguage),
                    createKeys: parsed.isSet(Flags.create)
                )
            )
            let report = try command.run(key: words[0], value: words[1], catalogPath: catalogArguments(parsed).first)
            return emit(report, json: json, text: renderer.render(report), strict: strict)

        case "lookup":
            let configuration = try makeConfiguration(parsed)
            let queries = wordArguments(parsed)
            guard !queries.isEmpty else { throw SmithError.usage("usage: \(spec.usage)") }
            let command = LookupCommand(
                workspace: Workspace(configuration: configuration),
                languages: CommandLineParser.languages(parsed)
            )
            let catalogs = catalogArguments(parsed)
            let reports = try command.run(queries: queries, catalogPaths: catalogs.isEmpty ? nil : catalogs)
            return emit(reports, json: json, text: renderer.render(reports), strict: strict)

        case "xcloc check":
            let configuration = try makeConfiguration(parsed)
            guard let bundle = parsed.positionals.first else {
                throw SmithError.usage("usage: \(spec.usage)")
            }
            let command = XclocCheckCommand(workspace: Workspace(configuration: configuration))
            let report = try command.run(bundlePath: bundle)
            return emit(
                report,
                format: format,
                configuration: configuration,
                text: renderer.render(report),
                strict: strict
            )

        case "xcloc apply":
            let configuration = try makeConfiguration(parsed)
            guard let bundle = parsed.positionals.first else {
                throw SmithError.usage("usage: \(spec.usage)")
            }
            if parsed.isSet(Flags.dryRun) && parsed.isSet(Flags.apply) {
                throw SmithError.usage("--dry-run and --apply contradict each other")
            }
            let command = XclocApplyCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    dryRun: !parsed.isSet(Flags.apply),
                    language: CommandLineParser.languages(parsed).first
                )
            )
            let report = WriteReports(command: "xcloc apply", reports: try command.run(bundlePath: bundle))
            if json {
                print(JSONWriter.text(report.jsonValue, style: .plain), terminator: "")
            } else {
                print(report.reports.map(renderer.render).joined(separator: "\n"))
                if !parsed.isSet(Flags.apply) {
                    print("Nothing was written. Re-run with --apply to import these translations.")
                }
            }
            return report.failures > 0 ? exitFindings : exitClean

        case "init":
            let result = try InitCommand(
                root: FileManager.default.currentDirectoryPath,
                force: parsed.isSet(Flags.force)
            ).run()
            print("Wrote \(result.path)")
            for target in result.targets {
                print("  \(target.name): \(target.catalogs.joined(separator: ", "))")
                print("    sources: \(target.sources.joined(separator: ", "))")
                if !target.referenceSources.isEmpty {
                    print("    reference-only: \(target.referenceSources.joined(separator: ", "))")
                }
            }
            let languageList = result.languages.isEmpty
                ? "(none found — add them)"
                : result.languages.joined(separator: ", ")
            print("  languages: \(languageList)")
            if !result.sharedDirectories.isEmpty {
                print("")
                print("\(result.sharedDirectories.joined(separator: ", ")) contain Swift but no catalog, so they are")
                print("listed as reference-only: their strings are not required to be in any catalog.")
                print("If a target compiles them, move them into that target's \"sources\".")
            }
            return exitClean

        default:
            printError("unknown command \"\(spec.name)\"")
            return exitError
        }
    } catch let error as SmithError {
        printError(error.description)
        return exitError
    } catch {
        printError("\(error)")
        return exitError
    }
}

exit(run())
