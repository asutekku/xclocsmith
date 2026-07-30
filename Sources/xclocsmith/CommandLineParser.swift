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
    var booleans: Set<String> = []
    var values: [String: [String]] = [:]

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
                    parsed.values[flag.name, default: []].append(arguments[index + 1])
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
        parsed.list(Flags.lang)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }
}
