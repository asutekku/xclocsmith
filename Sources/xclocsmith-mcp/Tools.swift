import Foundation
import XCLocSmithKit

/// One MCP tool.
///
/// The read/write split is the point of this server. Over a shell, anything that
/// can run `xclocsmith` can run `xclocsmith prune --apply --force`. Here the
/// commands that only read are separate tools from the ones that write, and each
/// carries the annotations a host uses to decide what to allow and what to
/// confirm.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    let properties: [String: JSONValue]
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let handler: (JSONValue) throws -> ToolResult

    var definition: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

struct ToolResult {
    let text: String
    let structured: JSONValue?
    var isError = false
}

enum Schema {
    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    static func bool(_ description: String, default defaultValue: Bool) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description),
            "default": .bool(defaultValue),
        ])
    }
    static func stringArray(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }
    static let projectRoot = string(
        "Absolute path to the project. A .xclocsmith.json is looked for here and above it; "
            + "without one the project is discovered. Required: an MCP server has no working directory."
    )
}

enum ToolRegistry {
    static func arguments(_ params: JSONValue) -> JSONValue {
        params["arguments"] ?? .object([:])
    }

    static func requireString(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw SmithError.usage("\"\(key)\" is required")
        }
        return value
    }

    static func strings(_ arguments: JSONValue, _ key: String) -> [String] {
        arguments[key]?.stringList ?? []
    }

    static func flag(_ arguments: JSONValue, _ key: String, default defaultValue: Bool = false) -> Bool {
        arguments[key]?.boolValue ?? defaultValue
    }

    static func workspace(_ arguments: JSONValue) throws -> Workspace {
        let root = try requireString(arguments, "projectRoot")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SmithError.usage("projectRoot \"\(root)\" is not a directory")
        }
        let configuration = try Configuration.load(
            explicitPath: arguments["configPath"]?.stringValue,
            useConfigFile: true,
            workingDirectory: root
        )
        return Workspace(configuration: configuration)
    }

    static func result(_ report: some Report, summary: String) -> ToolResult {
        ToolResult(text: summary, structured: report.jsonValue)
    }

    // MARK: - Tools

    static let all: [MCPTool] = [check, template, scan, lookup, xclocCheck, add, set, prune, xclocApply]

    static func tool(named name: String) -> MCPTool? { all.first { $0.name == name } }

    static let check = MCPTool(
        name: "check_catalogs",
        title: "Check translation coverage",
        description: """
            Translation coverage and catalog health for every string catalog in a project: \
            missing and empty translations, plural variations incomplete for the categories \
            a language actually requires, format specifiers that disagree with the source \
            string, and keys differing only by case. Reads only; writes nothing.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "languages": Schema.stringArray("Language codes to check. Defaults to every non-source language."),
            "catalogs": Schema.stringArray("Specific .xcstrings paths. Defaults to all of them."),
        ],
        required: ["projectRoot"],
        readOnly: true,
        destructive: false
    ) { arguments in
        let workspace = try workspace(arguments)
        let command = CheckCommand(
            workspace: workspace,
            options: .init(languages: strings(arguments, "languages"))
        )
        let catalogs = strings(arguments, "catalogs")
        let report = try command.run(catalogPaths: catalogs.isEmpty ? nil : catalogs)
        return result(report, summary: TextRenderer().render(report))
    }

    static let scan = MCPTool(
        name: "scan_sources",
        title: "Find unlocalized strings",
        description: """
            Finds user-visible strings in Swift source and checks each against the catalog \
            the call actually reaches, resolving tableName. Reports strings missing from a \
            catalog, strings present but untranslated, localization bypasses, and catalog \
            keys no source references. Reads only; writes nothing.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "languages": Schema.stringArray("Language codes to check. Defaults to every non-source language."),
            "includePreviews": Schema.bool("Include strings inside #Preview bodies.", default: false),
        ],
        required: ["projectRoot"],
        readOnly: true,
        destructive: false
    ) { arguments in
        let workspace = try workspace(arguments)
        if flag(arguments, "includePreviews") {
            var configuration = workspace.configuration
            configuration.scanPreviews = true
            let command = ScanCommand(
                workspace: Workspace(configuration: configuration),
                options: .init(languages: strings(arguments, "languages"))
            )
            let report = try command.run()
            return result(report, summary: TextRenderer().render(report))
        }
        let command = ScanCommand(
            workspace: workspace,
            options: .init(languages: strings(arguments, "languages"))
        )
        let report = try command.run()
        return result(report, summary: TextRenderer().render(report))
    }

    static let lookup = MCPTool(
        name: "lookup_keys",
        title: "Find existing catalog keys",
        description: """
            Searches every catalog for keys matching a query — exact, case variants, \
            substrings and fuzzy matches — with their translations. Use before adding a \
            key, so a project does not grow three spellings of the same string.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "queries": Schema.stringArray("Strings to look for."),
            "languages": Schema.stringArray("Languages whose translations to show."),
        ],
        required: ["projectRoot", "queries"],
        readOnly: true,
        destructive: false
    ) { arguments in
        let queries = strings(arguments, "queries")
        guard !queries.isEmpty else { throw SmithError.usage("\"queries\" needs at least one string") }
        let command = LookupCommand(
            workspace: try workspace(arguments),
            languages: strings(arguments, "languages")
        )
        let report = try command.run(queries: queries, catalogPaths: nil)
        return result(report, summary: TextRenderer().render(report))
    }

    static let template = MCPTool(
        name: "translation_template",
        title: "Get a fill-in template for what is missing",
        description: """
            Returns a fill-in payload for every untranslated key, in the shape the target \
            language requires: a plural key comes back with exactly the categories that \
            language uses — four for Russian, one for Japanese — and an identifier key comes \
            back with the source string and the developer's comment as context. Replace every \
            "TODO" and pass the result to add_translations, which will reject it if a format \
            specifier or a plural category went missing. Prefer this over composing a payload \
            from check_catalogs by hand; it is the same template the CLI writes for human \
            translators. One payload per catalog and language. Reads only; writes nothing.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "languages": Schema.stringArray("Language codes to fill in. Defaults to every non-source language."),
            "catalogs": Schema.stringArray("Specific .xcstrings paths. Defaults to all of them."),
        ],
        required: ["projectRoot"],
        readOnly: true,
        destructive: false
    ) { arguments in
        let workspace = try workspace(arguments)
        let command = CheckCommand(
            workspace: workspace,
            options: .init(languages: strings(arguments, "languages"))
        )
        let catalogs = strings(arguments, "catalogs")
        let report = try command.run(catalogPaths: catalogs.isEmpty ? nil : catalogs)
        let templates = command.templates(for: report)

        guard !templates.isEmpty else {
            return ToolResult(
                text: "Nothing is missing; there is no work to hand out.",
                structured: .object(["templates": .array([])])
            )
        }
        let summary = templates
            .map { "\($0.catalog) [\($0.language)]: \($0.keys.count) key(s) to fill in" }
            .joined(separator: "\n")
        return ToolResult(
            text: summary,
            structured: .object(["templates": .array(templates.map(\.document))])
        )
    }

    static let xclocCheck = MCPTool(
        name: "xcloc_check",
        title: "Validate a localization catalog",
        description: """
            Validates an .xcloc bundle or .xliff before it is imported: format specifiers in \
            each translation against its source, plural units against the categories the \
            target language requires, machine-translated units, metadata disagreements, and \
            units whose key is in no catalog. Reads only; writes nothing.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "bundlePath": Schema.string("Absolute path to the .xcloc bundle or .xliff file."),
        ],
        required: ["projectRoot", "bundlePath"],
        readOnly: true,
        destructive: false
    ) { arguments in
        let command = XclocCheckCommand(workspace: try workspace(arguments))
        let report = try command.run(bundlePath: try requireString(arguments, "bundlePath"))
        return result(report, summary: TextRenderer().render(report))
    }

    static let add = MCPTool(
        name: "add_translations",
        title: "Add translations",
        description: """
            Applies translations to one catalog. The payload is the xclocsmith/v1 envelope \
            ({format, catalog, language, strings}) — a template named by check or scan can be \
            passed back unchanged. Refuses to overwrite plural variations or substitutions \
            unless flatten is set, and refuses keys that collide with an existing key by case. \
            WRITES to the catalog unless dryRun is true.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "payload": .object([
                "type": .string("object"),
                "description": .string(
                    "The xclocsmith/v1 payload: {\"format\":\"xclocsmith/v1\",\"catalog\":…,"
                        + "\"language\":…,\"strings\":{\"Key\":\"translation\"}}. "
                        + "A value may also be {\"value\":…,\"state\":…,\"comment\":…} or "
                        + "{\"plural\":{\"one\":…,\"other\":…}}."
                ),
            ]),
            "catalog": Schema.string("Catalog path, when the payload does not name one."),
            "language": Schema.string("Language code, when the payload does not name one."),
            "dryRun": Schema.bool("Report what would change without writing.", default: false),
            "flatten": Schema.bool("Allow replacing plural variations or substitutions.", default: false),
        ],
        required: ["projectRoot", "payload"],
        readOnly: false,
        destructive: false
    ) { arguments in
        guard let payloadValue = arguments["payload"], payloadValue.objectValue != nil else {
            throw SmithError.usage("\"payload\" must be an object")
        }
        let payload = try TranslationPayload.load(from: payloadValue, path: "payload")
        let command = AddCommand(
            workspace: try workspace(arguments),
            options: .init(
                languages: arguments["language"]?.stringValue.map { [$0] } ?? [],
                flatten: flag(arguments, "flatten"),
                dryRun: flag(arguments, "dryRun")
            )
        )
        let report = try command.run(payload: payload, catalogPath: arguments["catalog"]?.stringValue)
        return result(report, summary: TextRenderer().render(report))
    }

    static let set = MCPTool(
        name: "set_translation",
        title: "Set one translation",
        description: """
            Sets a single translation. Will not create a key that is not already in the \
            catalog unless create is true, so a typo cannot quietly add one. \
            WRITES to the catalog unless dryRun is true.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "key": Schema.string("The catalog key."),
            "value": Schema.string("The translation."),
            "catalog": Schema.string("Catalog path. Required when the project has several."),
            "language": Schema.string("Language code."),
            "create": Schema.bool("Allow creating a key that is not in the catalog.", default: false),
            "dryRun": Schema.bool("Report what would change without writing.", default: false),
        ],
        required: ["projectRoot", "key", "value"],
        readOnly: false,
        destructive: false
    ) { arguments in
        let command = SetCommand(
            workspace: try workspace(arguments),
            options: .init(
                languages: arguments["language"]?.stringValue.map { [$0] } ?? [],
                dryRun: flag(arguments, "dryRun"),
                createKeys: flag(arguments, "create")
            )
        )
        let report = try command.run(
            key: try requireString(arguments, "key"),
            value: try requireString(arguments, "value"),
            catalogPath: arguments["catalog"]?.stringValue
        )
        return result(report, summary: TextRenderer().render(report))
    }

    static let prune = MCPTool(
        name: "prune_catalogs",
        title: "Remove unreferenced keys",
        description: """
            Removes catalog keys that no source file references. DESTRUCTIVE: with apply set \
            it deletes keys permanently, and keys built at runtime cannot be seen from source, \
            so the reported list should be reviewed first. Reports without writing unless \
            apply is true. Refuses to remove more than a quarter of a catalog without force.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "apply": Schema.bool("Actually delete the keys. Without this, nothing is written.", default: false),
            "force": Schema.bool("Override the safety guard on large deletions.", default: false),
        ],
        required: ["projectRoot"],
        readOnly: false,
        destructive: true
    ) { arguments in
        let command = PruneCommand(
            workspace: try workspace(arguments),
            options: .init(dryRun: !flag(arguments, "apply"), force: flag(arguments, "force"))
        )
        let report = WriteReports(command: "prune", reports: try command.run())
        var summary = report.reports.map(TextRenderer().render).joined(separator: "\n")
        if !flag(arguments, "apply") {
            summary += "\n\nNothing was written. Call again with apply: true to remove these keys."
        }
        return result(report, summary: summary)
    }

    static let xclocApply = MCPTool(
        name: "xcloc_apply",
        title: "Import a localization catalog",
        description: """
            Imports an .xcloc bundle or .xliff into the project's string catalogs, routing each \
            file element to the catalog for its table. Machine translation is imported as \
            needs_review. Never invents keys. WRITES to the catalogs unless apply is false. \
            Run xcloc_check first.
            """,
        properties: [
            "projectRoot": Schema.projectRoot,
            "bundlePath": Schema.string("Absolute path to the .xcloc bundle or .xliff file."),
            "apply": Schema.bool("Actually write the translations.", default: false),
            "language": Schema.string("Override the language the bundle declares."),
        ],
        required: ["projectRoot", "bundlePath"],
        readOnly: false,
        destructive: false
    ) { arguments in
        let command = XclocApplyCommand(
            workspace: try workspace(arguments),
            options: .init(
                dryRun: !flag(arguments, "apply"),
                language: arguments["language"]?.stringValue
            )
        )
        let reports = try command.run(bundlePath: try requireString(arguments, "bundlePath"))
        let report = WriteReports(command: "xcloc apply", reports: reports)
        var summary = report.reports.map(TextRenderer().render).joined(separator: "\n")
        if !flag(arguments, "apply") {
            summary += "\n\nNothing was written. Call again with apply: true to import these translations."
        }
        return result(report, summary: summary)
    }
}
