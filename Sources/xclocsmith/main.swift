import Foundation
import XCLocSmithKit

// Exit codes: 0 clean, 1 findings, 2 usage or I/O error.
let exitClean: Int32 = 0
let exitFindings: Int32 = 1
let exitError: Int32 = 2

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("xclocsmith: " + message + "\n").utf8))
}

func emit(_ report: some Report, json: Bool, text: @autoclosure () -> String, strict: Bool) -> Int32 {
    if json {
        print(JSONWriter.text(report.jsonValue, style: .plain), terminator: "")
    } else {
        print(text())
    }
    if report.failures > 0 { return exitFindings }
    if strict && report.advisories > 0 { return exitFindings }
    return exitClean
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
    parsed.positionals.filter { $0.hasSuffix(".xcstrings") }
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
    guard let spec = Registry.command(named: first) else {
        printError("unknown command \"\(first)\". Run `xclocsmith --help`.")
        return exitError
    }

    let rest = Array(arguments.dropFirst())
    if rest.contains("--help") || rest.contains("-h") {
        print(Help.command(spec))
        return exitClean
    }

    do {
        let parsed = try CommandLineParser.parse(arguments: rest, spec: spec)
        let renderer = TextRenderer()
        let json = parsed.isSet(Flags.json)
        let strict = parsed.isSet(Flags.strict)

        switch spec.name {
        case "check":
            let configuration = try makeConfiguration(parsed)
            var command = CheckCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    templatePath: parsed.value(Flags.out)
                )
            )
            let catalogs = catalogArguments(parsed)
            let report = try command.run(catalogPaths: catalogs.isEmpty ? nil : catalogs)
            return emit(report, json: json, text: renderer.render(report), strict: strict)

        case "scan":
            var configuration = try makeConfiguration(parsed)
            let directories = parsed.positionals.filter { !$0.hasSuffix(".xcstrings") }
            if !directories.isEmpty {
                configuration.targets = configuration.targets.map {
                    Target(name: $0.name, sources: directories, referenceSources: [], catalogs: $0.catalogs)
                }
            }
            // Writing files is opt-in: a scan that litters the work tree breaks
            // any pipeline with a clean-tree check.
            let wantsTemplate = parsed.isSet(Flags.template) || parsed.value(Flags.out) != nil
            var command = ScanCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    languages: CommandLineParser.languages(parsed),
                    writeTemplates: wantsTemplate && !parsed.isSet(Flags.noTemplate),
                    templatePath: parsed.value(Flags.out),
                    includeFormatKeysInOrphans: parsed.isSet(Flags.includeFormatKeys)
                )
            )
            let report = try command.run()
            return emit(report, json: json, text: renderer.render(report), strict: strict)

        case "prune":
            let configuration = try makeConfiguration(parsed)
            if parsed.isSet(Flags.dryRun) && parsed.isSet(Flags.apply) {
                throw SmithError.usage("--dry-run and --apply contradict each other")
            }
            var command = PruneCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(
                    dryRun: !parsed.isSet(Flags.apply),
                    force: parsed.isSet(Flags.force),
                    includeFormatKeys: parsed.isSet(Flags.includeFormatKeys)
                )
            )
            let reports = try command.run()
            if json {
                print(JSONWriter.text(.object([
                    "command": .string("prune"),
                    "catalogs": .array(reports.map(\.jsonValue)),
                    "failures": .number("\(reports.reduce(0) { $0 + $1.failures })"),
                ]), style: .plain), terminator: "")
            } else {
                print(reports.map(renderer.render).joined(separator: "\n"))
                if !parsed.isSet(Flags.apply) {
                    print("Nothing was written. Re-run with --apply to remove these keys.")
                }
            }
            return reports.contains { $0.failures > 0 } ? exitError : exitClean

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
            var command = AddCommand(
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
            let words = parsed.positionals.filter { !$0.hasSuffix(".xcstrings") }
            guard words.count == 2 else {
                throw SmithError.usage("usage: \(spec.usage)")
            }
            var command = SetCommand(
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
            let queries = parsed.positionals.filter { !$0.hasSuffix(".xcstrings") }
            guard !queries.isEmpty else { throw SmithError.usage("usage: \(spec.usage)") }
            var command = LookupCommand(
                workspace: Workspace(configuration: configuration),
                languages: CommandLineParser.languages(parsed)
            )
            let catalogs = catalogArguments(parsed)
            let reports = try command.run(queries: queries, catalogPaths: catalogs.isEmpty ? nil : catalogs)
            return emit(reports, json: json, text: renderer.render(reports), strict: strict)

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
