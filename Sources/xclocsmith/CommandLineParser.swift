import Foundation
import XCLocSmithKit

/// A flag, declared per command.
///
/// Every command states exactly which flags it accepts, and anything else is a
/// usage error. A tool that quietly ignores `--dry-run` on a command that
/// writes is worse than one that has no `--dry-run` at all.
struct Flag: Hashable {
    let name: String
    let takesValue: Bool
    let help: String

    static func bool(_ name: String, _ help: String) -> Flag {
        Flag(name: name, takesValue: false, help: help)
    }
    static func value(_ name: String, _ help: String) -> Flag {
        Flag(name: name, takesValue: true, help: help)
    }
}

enum Flags {
    static let lang = Flag.value("--lang", "Language code; repeatable, comma-separated, or \"all\".")
    static let config = Flag.value("--config", "Path to a \(Configuration.fileName).")
    static let noConfig = Flag.bool("--no-config", "Ignore configuration files; discover the project instead.")
    static let json = Flag.bool("--json", "Emit the report as JSON.")
    // Names `--json` rather than the other way round: a flag's help is printed
    // by every command that accepts it, and naming a flag the command rejects
    // advertises something the parser will refuse.
    static let format = Flag.value(
        "--format",
        "Output format: text (default), json, sarif, github. --json is the same as json."
    )
    static let strict = Flag.bool("--strict", "Treat advisory findings as failures.")
    static let out = Flag.value("--out", "Path for the translation template.")
    static let template = Flag.bool("--template", "Write a translation template for what is missing.")
    static let noTemplate = Flag.bool("--no-template", "Do not write a translation template.")
    static let dryRun = Flag.bool("--dry-run", "Report what would change without writing.")
    static let apply = Flag.bool("--apply", "Actually write the changes.")
    static let force = Flag.bool("--force", "Override safety checks.")
    static let state = Flag.value("--state", "Translation state to write (new, needs_review, translated).")
    static let flatten = Flag.bool("--flatten", "Allow overwriting plural variations or substitutions.")
    static let create = Flag.bool("--create", "Allow creating keys that are not in the catalog yet.")
    static let addLanguage = Flag.bool("--add-language", "Allow writing a language the catalog does not have yet.")
    static let previews = Flag.bool("--previews", "Include strings inside #Preview / PreviewProvider bodies.")
    static let includeFormatKeys = Flag.bool("--include-format-keys", "Consider keys containing %@ / %lld when reporting orphans.")
    static let threshold = Flag.value("--threshold", "Near-duplicate threshold, 50–99 (default 85).")
    static let files = Flag.value("--files", "Report only these source files; repeatable or comma-separated.")
}

struct CommandSpec {
    let name: String
    let summary: String
    let usage: String
    let flags: [Flag]
    let discussion: String?

    func flag(named name: String) -> Flag? { flags.first { $0.name == name } }
}

struct ParsedCommand {
    let spec: CommandSpec
    var positionals: [String] = []
    /// Positionals given after `--`. These are words — a key, a query — and are
    /// never re-read as file paths, so a key may be any string at all.
    var literalPositionals: Set<Int> = []
    var booleans: Set<String> = []
    var values: [String: [String]] = [:]

    /// Positionals that may still be classified by their suffix.
    var classifiablePositionals: [String] {
        positionals.enumerated()
            .filter { !literalPositionals.contains($0.offset) }
            .map(\.element)
    }

    func isSet(_ flag: Flag) -> Bool { booleans.contains(flag.name) }
    func value(_ flag: Flag) -> String? { values[flag.name]?.last }
    func list(_ flag: Flag) -> [String] { values[flag.name] ?? [] }
}

enum CommandLineParser {
    static func parse(arguments: [String], spec: CommandSpec) throws -> ParsedCommand {
        var parsed = ParsedCommand(spec: spec)
        var index = 0
        var seenSeparator = false

        while index < arguments.count {
            let argument = arguments[index]

            if seenSeparator {
                parsed.literalPositionals.insert(parsed.positionals.count)
                parsed.positionals.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                seenSeparator = true
                index += 1
                continue
            }
            if argument == "-" || !argument.hasPrefix("-") {
                parsed.positionals.append(argument)
                index += 1
                continue
            }

            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }

            guard let flag = spec.flag(named: name) else {
                throw SmithError.usage(unknownFlagMessage(name, spec: spec))
            }
            if flag.takesValue {
                if let inlineValue {
                    parsed.values[flag.name, default: []].append(inlineValue)
                    index += 1
                } else {
                    guard index + 1 < arguments.count else {
                        throw SmithError.usage("\(flag.name) needs a value")
                    }
                    let value = arguments[index + 1]
                    // `scan --out --json` means the user forgot the filename,
                    // not that they want a file called "--json" — and swallowing
                    // it writes one. `--out=--json` remains available for the
                    // pathological case.
                    guard value != "--", !Registry.allFlags.contains(value) else {
                        throw SmithError.usage(
                            "\(flag.name) needs a value, but the next argument is \(value)"
                        )
                    }
                    parsed.values[flag.name, default: []].append(value)
                    index += 2
                }
            } else {
                if inlineValue != nil {
                    throw SmithError.usage("\(flag.name) does not take a value")
                }
                parsed.booleans.insert(flag.name)
                index += 1
            }
        }
        return parsed
    }

    private static func unknownFlagMessage(_ name: String, spec: CommandSpec) -> String {
        let accepted = spec.flags.map(\.name).sorted().joined(separator: ", ")
        let knownElsewhere = Registry.allFlags.contains(name)
        let hint = knownElsewhere
            ? "\(name) is not accepted by `\(spec.name)`."
            : "unknown option \(name)."
        return "\(hint)\n\(spec.name) accepts: \(accepted)\nRun `xclocsmith \(spec.name) --help`."
    }

    /// Splits `--lang ja,de --lang fr` into `["ja", "de", "fr"]`.
    static func languages(_ parsed: ParsedCommand) -> [String] {
        split(parsed.list(Flags.lang))
    }

    static func files(_ parsed: ParsedCommand) -> [String] {
        split(parsed.list(Flags.files))
    }

    /// `--json` is the older spelling of `--format json`, kept because scripts
    /// use it. Given both, they must agree — silently preferring one would make
    /// `--json --format sarif` write a format the caller did not ask for.
    static func format(_ parsed: ParsedCommand) throws -> OutputFormat {
        guard let raw = parsed.value(Flags.format) else {
            return parsed.isSet(Flags.json) ? .json : .text
        }
        guard let format = OutputFormat(rawValue: raw) else {
            let known = OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw SmithError.usage("--format takes one of: \(known) (got \"\(raw)\")")
        }
        if parsed.isSet(Flags.json), format != .json {
            throw SmithError.usage("--json and --format \(raw) contradict each other")
        }
        return format
    }

    private static func split(_ values: [String]) -> [String] {
        values
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }
}
