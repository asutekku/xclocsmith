import Foundation
import XCLocSmithKit

let toolVersion = "0.1.0"

enum Registry {
    static let check = CommandSpec(
        name: "check",
        summary: "Translation coverage and catalog health.",
        usage: "xclocsmith check [catalog.xcstrings ...]",
        flags: [
            Flags.lang, Flags.config, Flags.noConfig, Flags.json, Flags.strict,
            Flags.out, Flags.threshold,
        ],
        discussion: """
            Reports, per catalog and language: missing and empty translations,
            incomplete plural variations for the categories the language actually
            requires, format specifiers that disagree with the source string, and
            keys that differ only by case.

            Writes nothing unless --out is given.
            """
    )

    static let scan = CommandSpec(
        name: "scan",
        summary: "Find user-visible strings in source and check them against the catalogs.",
        usage: "xclocsmith scan [directory ...]",
        flags: [
            Flags.lang, Flags.config, Flags.noConfig, Flags.json, Flags.strict,
            Flags.out, Flags.template, Flags.noTemplate, Flags.previews,
            Flags.includeFormatKeys,
        ],
        discussion: """
            Resolves each call to the table it asks for, so a key in Errors.xcstrings
            does not satisfy a lookup in Localizable.xcstrings.

            Writes a translation template only when --template or --out is given.
            """
    )

    static let prune = CommandSpec(
        name: "prune",
        summary: "Remove catalog keys that no source file references.",
        usage: "xclocsmith prune [--apply]",
        flags: [
            Flags.config, Flags.noConfig, Flags.json, Flags.apply, Flags.dryRun,
            Flags.force, Flags.includeFormatKeys,
        ],
        discussion: """
            Reports without writing unless --apply is given.

            Refuses to remove more than a quarter of a catalog without --force:
            a number that high almost always means a source directory is missing
            from the configuration. Keys built at runtime cannot be seen from
            source, so review the list before applying.
            """
    )

    static let add = CommandSpec(
        name: "add",
        summary: "Apply a payload of translations to a catalog.",
        usage: "xclocsmith add <translations.json|-> [catalog.xcstrings]",
        flags: [
            Flags.lang, Flags.config, Flags.noConfig, Flags.json, Flags.state,
            Flags.flatten, Flags.dryRun, Flags.addLanguage,
        ],
        discussion: """
            A template written by `check --out` or `scan --template` names its own
            catalog and language, so it can be applied with no other arguments.

            Refuses to overwrite plural variations or substitutions with a plain
            string unless --flatten is given.
            """
    )

    static let set = CommandSpec(
        name: "set",
        summary: "Set one translation.",
        usage: "xclocsmith set \"key\" \"value\" [catalog.xcstrings]",
        flags: [
            Flags.lang, Flags.config, Flags.noConfig, Flags.json, Flags.state,
            Flags.flatten, Flags.dryRun, Flags.create, Flags.addLanguage,
        ],
        discussion: """
            Refuses to create a key that is not already in the catalog unless
            --create is given, so a typo cannot silently add one.
            """
    )

    static let lookup = CommandSpec(
        name: "lookup",
        summary: "Find existing keys before adding a new one.",
        usage: "xclocsmith lookup \"query\" [\"query\" ...]",
        flags: [Flags.lang, Flags.config, Flags.noConfig, Flags.json],
        discussion: "Exits 1 when nothing matched, so it can gate a script."
    )

    static let initialize = CommandSpec(
        name: "init",
        summary: "Write a \(Configuration.fileName) describing this project.",
        usage: "xclocsmith init [--force]",
        flags: [Flags.force],
        discussion: nil
    )

    static let all: [CommandSpec] = [check, scan, prune, add, set, lookup, initialize]

    static var allFlags: Set<String> {
        Set(all.flatMap { $0.flags.map(\.name) })
    }

    static func command(named name: String) -> CommandSpec? {
        all.first { $0.name == name }
    }
}

enum Help {
    static func global() -> String {
        var lines = [
            "xclocsmith \(toolVersion) — audit and edit Xcode String Catalogs (.xcstrings)",
            "",
            "Usage: xclocsmith <command> [options]",
            "",
            "Commands:",
        ]
        let width = Registry.all.map(\.name.count).max() ?? 8
        for command in Registry.all {
            let padding = String(repeating: " ", count: width - command.name.count)
            lines.append("  \(command.name)\(padding)  \(command.summary)")
        }
        lines.append(contentsOf: [
            "",
            "Run `xclocsmith <command> --help` for the flags a command accepts.",
            "",
            "Configuration: \(Configuration.fileName), found by walking up from the working",
            "directory. `xclocsmith init` writes one. Without it the project is discovered.",
            "",
            "Exit codes: 0 clean, 1 findings, 2 usage or I/O error.",
        ])
        return lines.joined(separator: "\n")
    }

    static func command(_ spec: CommandSpec) -> String {
        var lines = [spec.summary, "", "Usage: \(spec.usage)", ""]
        if let discussion = spec.discussion {
            lines.append(discussion)
            lines.append("")
        }
        lines.append("Options:")
        let width = spec.flags.map(\.name.count).max() ?? 10
        for flag in spec.flags.sorted(by: { $0.name < $1.name }) {
            let padding = String(repeating: " ", count: width - flag.name.count)
            lines.append("  \(flag.name)\(padding)  \(flag.help)")
        }
        lines.append("  --help\(String(repeating: " ", count: max(0, width - 6)))  Show this message.")
        return lines.joined(separator: "\n")
    }
}
