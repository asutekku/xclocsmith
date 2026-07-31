import Foundation

/// How a report is written out.
public enum OutputFormat: String, Sendable, CaseIterable {
    case text
    case json
    /// SARIF 2.1.0, which GitHub code scanning ingests.
    case sarif
    /// GitHub Actions workflow commands, which annotate the pull request diff.
    case github
}

/// Renderers for the two formats a machine reads.
///
/// Both work from `Report.findings` rather than from the reports themselves, so
/// a finding cannot exist in the terminal output and be missing from the pull
/// request. Both also resolve a catalog key to the line it sits on, because an
/// annotation without a line lands on row one of a four-thousand-line file and
/// is worse than useless on a diff.
public struct MachineRenderer {
    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Findings with a line filled in wherever one can be found.
    func located(_ findings: [Finding]) -> [Finding] {
        var indexes: [String: CatalogLineIndex?] = [:]
        return findings.map { finding in
            guard finding.line == nil, let key = finding.key, let file = finding.file else {
                return finding
            }
            let absolute = configuration.absolute(file)
            let index: CatalogLineIndex?
            if let cached = indexes[absolute] {
                index = cached
            } else {
                index = CatalogLineIndex(path: absolute)
                indexes[absolute] = index
            }
            guard let line = index?.line(of: key) else { return finding }
            return Finding(
                rule: finding.rule,
                level: finding.level,
                message: finding.message,
                file: finding.file,
                line: line,
                key: finding.key
            )
        }
    }

    // MARK: - GitHub Actions

    /// One workflow command per finding.
    ///
    /// The message is flattened to a single line: a `%0A` escape would render
    /// the newline, but a multi-line annotation is unreadable in the diff view
    /// and the detail is in the job log anyway.
    public func github(_ report: some Report) -> String {
        located(report.findings).map { finding in
            var parameters: [String] = []
            if let file = finding.file { parameters.append("file=\(escape(property: file))") }
            if let line = finding.line { parameters.append("line=\(line)") }
            parameters.append("title=\(escape(property: finding.rule))")
            let command = finding.level == .note ? "notice" : finding.level.rawValue
            let prefix = parameters.isEmpty ? "" : " " + parameters.joined(separator: ",")
            return "::\(command)\(prefix)::\(escape(data: finding.message))"
        }
        .joined(separator: "\n")
    }

    /// GitHub's workflow-command escaping. Without it a message containing a
    /// newline silently truncates the annotation at the newline, and one
    /// containing `::` can close the command early.
    private func escape(data value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private func escape(property value: String) -> String {
        escape(data: value)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }

    // MARK: - SARIF

    public func sarif(_ report: some Report, toolVersion: String) -> String {
        let findings = located(report.findings)

        // Every rule that fired, declared once. GitHub's code-scanning UI reads
        // these for the name it shows beside an alert; a result whose ruleId is
        // in no rule table is displayed as a bare identifier.
        var ruleIDs: [String] = []
        var seen = Set<String>()
        for finding in findings where seen.insert(finding.rule).inserted {
            ruleIDs.append(finding.rule)
        }
        let rules = ruleIDs.map { rule in
            // GitHub's SARIF ingestion marks `fullDescription.text` and
            // `help.text` as required alongside `id` — the spec wants only the
            // id — and refuses empty strings for required properties. One
            // sentence serves all three rather than inventing three wordings.
            let description = RuleCatalogue.description(of: rule)
            return JSONValue.object([
                "id": .string(rule),
                "name": .string(rule),
                "shortDescription": .object(["text": .string(description)]),
                "fullDescription": .object(["text": .string(description)]),
                "help": .object(["text": .string(description)]),
                "defaultConfiguration": .object([
                    "level": .string(RuleCatalogue.defaultLevel(of: rule)),
                ]),
            ])
        }

        let results = findings.map { finding -> JSONValue in
            var fields: [String: JSONValue] = [
                "ruleId": .string(finding.rule),
                // SARIF has no "note"; "note" is its lowest level and matches.
                "level": .string(finding.level.rawValue),
                "message": .object(["text": .string(finding.message)]),
            ]
            if let file = finding.file {
                var region: [String: JSONValue] = [:]
                // SARIF regions are 1-based and a startLine of 0 is invalid, so
                // a finding with no line carries no region at all.
                if let line = finding.line, line > 0 { region["startLine"] = .number("\(line)") }
                // The uri must be a valid RFC 3986 reference, so spaces and
                // friends are percent-encoded. A repo-relative path pairs with
                // %SRCROOT%; an absolute path (a catalog outside the project, a
                // bundle named absolutely) becomes a file: URI instead — the
                // spec forbids uriBaseId next to an absolute URI, and a
                // relative reference is not allowed to start with "/".
                let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
                var artifact: [String: JSONValue]
                if file.hasPrefix("/") {
                    artifact = ["uri": .string("file://" + encoded)]
                } else {
                    artifact = ["uri": .string(encoded), "uriBaseId": .string("%SRCROOT%")]
                }
                var location: [String: JSONValue] = [
                    "artifactLocation": .object(artifact),
                ]
                if !region.isEmpty { location["region"] = .object(region) }
                fields["locations"] = .array([.object(["physicalLocation": .object(location)])])
            }
            return .object(fields)
        }

        let document = JSONValue.object([
            "version": .string("2.1.0"),
            "$schema": .string("https://json.schemastore.org/sarif-2.1.0.json"),
            "runs": .array([.object([
                "tool": .object(["driver": .object([
                    "name": .string("xclocsmith"),
                    "version": .string(toolVersion),
                    "informationUri": .string("https://github.com/akko/xclocsmith"),
                    "rules": .array(rules),
                ])]),
                "results": .array(results),
            ])]),
        ])
        return JSONWriter.text(document, style: .plain)
    }
}

/// What each rule means, for the SARIF rule table.
enum RuleCatalogue {
    private static let entries: [String: (String, String)] = [
        "missing-translation": ("A key has no translation in a language being checked.", "error"),
        "empty-translation": ("A key's translation is present but empty.", "error"),
        "plural-incomplete": ("A translation is missing plural categories the language requires.", "error"),
        "format-mismatch": ("A translation's format specifiers disagree with the source string.", "error"),
        "glossary": ("A translation does not use the rendering the glossary fixes for a term.", "error"),
        "case-collision": ("Keys differ only by case and both generate symbols.", "error"),
        "case-variant": ("Keys differ only by case.", "warning"),
        "duplicate-source": ("Several keys share one source string.", "warning"),
        "divergent-translation": ("One source string is translated more than one way.", "warning"),
        "near-duplicate": ("Two source strings are nearly identical.", "warning"),
        "identical-to-source": ("A translation is identical to the source string.", "warning"),
        "needs-review": ("A translation is marked needs_review.", "warning"),
        "stale-key": ("Xcode marked a key stale; it is no longer found in source.", "note"),
        "string-not-in-catalog": ("A user-visible string in source is in no catalog.", "error"),
        "untranslated-string": ("A string used in source has no translation.", "error"),
        "localization-bypass": ("Source deliberately shows a string without localizing it.", "warning"),
        "orphaned-key": ("A catalog key nothing in source references.", "warning"),
        "unknown-key": ("An imported unit's key is in no catalog of this project.", "warning"),
        "unsupported-unit": ("An imported unit has an id shape this tool will not guess at.", "warning"),
        "machine-translated": ("An imported unit is machine translation.", "warning"),
        "missing-from-bundle": ("A catalog key the imported bundle never mentions.", "warning"),
        "bundle-metadata": ("An imported bundle's metadata is inconsistent.", "error"),
        "end-punctuation": ("A translation ends in different punctuation from its source.", "warning"),
        "edge-whitespace": ("Leading or trailing space that disagrees with the source.", "warning"),
        "double-space": ("Two spaces in a row where the source has one.", "warning"),
        "newline-count": ("A translation has a different number of line breaks from its source.", "error"),
        "invisible-character": ("A translation contains an invisible character that breaks string comparison.", "error"),
        "bidi-control": ("A translation contains a bidirectional override or an unclosed embedding.", "error"),
        "replacement-character": ("A translation contains U+FFFD, so text was lost converting encodings.", "error"),
        "punctuation-spacing": ("French punctuation without its non-breaking space.", "warning"),
        "doubled-word": ("The same word twice in a row.", "warning"),
        "markdown": ("A translation broke Markdown the source uses.", "error"),
        "inflection-dropped": ("A translation dropped the grammar-agreement markup its source uses.", "error"),
        "same-plurals": ("Every plural category filled with the same text.", "warning"),
        "placeholder-translation": ("A dash or a note-to-self where a translation should be.", "error"),
        "ellipsis-style": ("A source string uses three full stops where the typographic ellipsis belongs.", "warning"),
        "unordered-specifiers": ("A source string has specifiers no translation can reorder.", "warning"),
        "dropped-specifier-position": ("A translation dropped the argument positions the source gave it.", "error"),
        "info-plist-not-localized": ("An Info.plist string users read has no catalog entry.", "warning"),
        "development-region-mismatch": ("The bundle's development region is not the catalog's source language.", "warning"),
        "language-coverage-gap": ("A catalog ships fewer languages than the project's other catalogs.", "warning"),
        "configuration": ("A file could not be read, or the project is misconfigured.", "error"),
    ]

    static func description(of rule: String) -> String {
        entries[rule]?.0 ?? rule
    }

    static func defaultLevel(of rule: String) -> String {
        entries[rule]?.1 ?? "warning"
    }
}
