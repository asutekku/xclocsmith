import Foundation

/// Renders reports for people.
///
/// Rules this output follows, because the previous tool broke all of them:
/// findings come before diagnostics, failures are marked differently from
/// advisories, every truncated list says how much it truncated, and the run
/// always ends with one line stating what happened and why the exit code is
/// what it is.
public struct TextRenderer {
    public var maximumListLength: Int

    public init(maximumListLength: Int = 50) {
        self.maximumListLength = maximumListLength
    }

    private func list(_ items: [String], indent: String = "    ", prefix: String = "- ") -> [String] {
        var lines = items.prefix(maximumListLength).map { "\(indent)\(prefix)\(escaped($0))" }
        if items.count > maximumListLength {
            lines.append("\(indent)… and \(items.count - maximumListLength) more")
        }
        return lines
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - check

    public func render(_ report: CheckReport) -> String {
        var lines: [String] = []

        for catalog in report.catalogs {
            lines.append("\(catalog.path)  (\(catalog.table), source \(catalog.sourceLanguage))")
            lines.append("  \(catalog.keyCount) keys, \(catalog.translatableCount) translatable")

            for coverage in catalog.coverage {
                var summary = "  \(coverage.language): \(coverage.translated)/\(coverage.translatable) (\(coverage.percent)%)"
                if coverage.isSourceLanguage { summary += "  [source]" }
                if !coverage.missing.isEmpty { summary += "  missing \(coverage.missing.count)" }
                if !coverage.empty.isEmpty { summary += "  empty \(coverage.empty.count)" }
                if !coverage.needsReview.isEmpty { summary += "  unreviewed \(coverage.needsReview.count)" }
                lines.append(summary)
            }

            for coverage in catalog.coverage where !coverage.isSourceLanguage {
                let outstanding = (coverage.missing + coverage.empty).sorted()
                guard !outstanding.isEmpty else { continue }
                lines.append("")
                lines.append("  FAIL  missing \(coverage.language) translations (\(outstanding.count)):")
                lines.append(contentsOf: list(outstanding))
            }

            if !catalog.pluralGaps.isEmpty {
                lines.append("")
                lines.append("  FAIL  incomplete plural variations (\(catalog.pluralGaps.count)):")
                for gap in catalog.pluralGaps.prefix(maximumListLength) {
                    lines.append("    - [\(gap.language)] \"\(escaped(gap.key))\" needs \(gap.missingCategories.joined(separator: ", "))")
                }
                if catalog.pluralGaps.count > maximumListLength {
                    lines.append("    … and \(catalog.pluralGaps.count - maximumListLength) more")
                }
            }

            if !catalog.formatMismatches.isEmpty {
                lines.append("")
                lines.append("  FAIL  format specifiers disagree with the source string (\(catalog.formatMismatches.count)):")
                for mismatch in catalog.formatMismatches.prefix(maximumListLength) {
                    lines.append("    - [\(mismatch.language)] \"\(escaped(mismatch.key))\" \(mismatch.problem)")
                    if let source = mismatch.source, let translation = mismatch.translation {
                        lines.append("        \"\(escaped(source))\"  →  \"\(escaped(translation))\"")
                    }
                }
                if catalog.formatMismatches.count > maximumListLength {
                    lines.append("    … and \(catalog.formatMismatches.count - maximumListLength) more")
                }
            }

            if !catalog.glossaryViolations.isEmpty {
                lines.append("")
                lines.append("  FAIL  glossary terms not used (\(catalog.glossaryViolations.count)):")
                for violation in catalog.glossaryViolations.prefix(maximumListLength) {
                    lines.append(
                        "    - [\(violation.language)] \"\(escaped(violation.term))\" must render as \"\(escaped(violation.expected))\""
                    )
                    lines.append("        \"\(escaped(violation.source))\"  →  \"\(escaped(violation.translation))\"")
                }
                if catalog.glossaryViolations.count > maximumListLength {
                    lines.append("    … and \(catalog.glossaryViolations.count - maximumListLength) more")
                }
            }

            let breaking = catalog.caseDuplicates.filter(\.breaksSymbolGeneration)
            if !breaking.isEmpty {
                lines.append("")
                lines.append("  FAIL  keys differing only by case, with generated symbols (\(breaking.count)):")
                for duplicate in breaking {
                    lines.append("    - \(duplicate.keys.map { "\"\(escaped($0))\"" }.joined(separator: " vs "))")
                }
                lines.append("    Xcode cannot generate symbols for both; rename one or use the existing key.")
            }

            let harmless = catalog.caseDuplicates.filter { !$0.breaksSymbolGeneration }
            if !harmless.isEmpty {
                lines.append("")
                lines.append("  note  keys differing only by case (\(harmless.count)) — extracted, so symbol generation is unaffected:")
                for duplicate in harmless.prefix(maximumListLength) {
                    lines.append("    - \(duplicate.keys.map { "\"\(escaped($0))\"" }.joined(separator: " vs "))")
                }
            }

            let divergent = catalog.duplicateSources.filter { !$0.divergences.isEmpty }
            if !divergent.isEmpty {
                lines.append("")
                lines.append("  note  one source string translated more than one way (\(divergent.count)):")
                for duplicate in divergent.prefix(maximumListLength) {
                    lines.append("    - \"\(escaped(duplicate.text))\"  \(duplicate.keys.joined(separator: ", "))")
                    for divergence in duplicate.divergences.prefix(4) {
                        // Keys sharing a rendering are grouped, so a string
                        // under six keys with two translations reads as two
                        // choices rather than six lines.
                        var order: [String] = []
                        var byValue: [String: [String]] = [:]
                        for rendering in divergence.renderings {
                            if byValue[rendering.value] == nil { order.append(rendering.value) }
                            byValue[rendering.value, default: []].append(rendering.key)
                        }
                        let rendered = order.map { value in
                            "\"\(escaped(value))\" (\(byValue[value, default: []].joined(separator: ", ")))"
                        }
                        lines.append("        [\(divergence.language)] \(rendered.joined(separator: "  vs  "))")
                    }
                    if duplicate.divergences.count > 4 {
                        lines.append("        … and \(duplicate.divergences.count - 4) more language(s)")
                    }
                }
                if divergent.count > maximumListLength {
                    lines.append("    … and \(divergent.count - maximumListLength) more")
                }
            }

            let consistent = catalog.duplicateSources.filter { $0.divergences.isEmpty }
            if !consistent.isEmpty {
                lines.append("")
                lines.append("  note  duplicate source strings, translated the same everywhere (\(consistent.count)):")
                for duplicate in consistent.prefix(maximumListLength) {
                    lines.append("    - \"\(escaped(duplicate.text))\"  \(duplicate.keys.joined(separator: ", "))")
                }
                if consistent.count > maximumListLength {
                    lines.append("    … and \(consistent.count - maximumListLength) more")
                }
            }

            if !catalog.similarKeys.isEmpty {
                lines.append("")
                lines.append("  note  near-duplicate strings (\(catalog.similarKeys.count)):")
                for pair in catalog.similarKeys.prefix(maximumListLength) {
                    // Identifier keys do not show what was compared, so the
                    // source text goes on the line beside them.
                    func side(_ key: String, _ text: String?) -> String {
                        guard let text else { return "\"\(escaped(key))\"" }
                        return "\(key) (\"\(escaped(text))\")"
                    }
                    lines.append(
                        "    - \(pair.percent)%  \(side(pair.a, pair.aText))  vs  \(side(pair.b, pair.bText))"
                    )
                }
                if catalog.similarKeys.count > maximumListLength {
                    lines.append("    … and \(catalog.similarKeys.count - maximumListLength) more")
                }
                lines.append("    Add deliberate pairs to \"ignoreSimilar\" in \(Configuration.fileName).")
            }

            for coverage in catalog.coverage where !coverage.identicalToSource.isEmpty {
                lines.append("")
                lines.append("  note  \(coverage.identicalToSource.count) \(coverage.language) value(s) identical to the source key:")
                lines.append(contentsOf: list(coverage.identicalToSource))
            }

            if !catalog.staleKeys.isEmpty {
                lines.append("")
                lines.append("  note  \(catalog.staleKeys.count) stale key(s) — Xcode marked these as gone from source; `prune` removes them")
            }
            lines.append("")
        }

        lines.append(contentsOf: renderDiagnostics(report.diagnostics))
        for path in report.templatesWritten {
            lines.append("Wrote \(path)")
        }
        lines.append(summary(failures: report.failures, advisories: report.advisories))
        return lines.joined(separator: "\n")
    }

    // MARK: - scan

    public func render(_ report: ScanReport) -> String {
        var lines: [String] = []

        if !report.missingKeys.isEmpty {
            lines.append("FAIL  strings not in a catalog (\(report.missingKeys.count)):")
            for finding in report.missingKeys.prefix(maximumListLength) {
                lines.append("  \(finding.file):\(finding.line)  [\(finding.context)]  \"\(escaped(finding.value))\"")
                lines.append("      → \(finding.catalog)")
            }
            if report.missingKeys.count > maximumListLength {
                lines.append("  … and \(report.missingKeys.count - maximumListLength) more")
            }
            lines.append("")
        }

        if !report.untranslated.isEmpty {
            lines.append("FAIL  strings in a catalog but untranslated (\(report.untranslated.count)):")
            for finding in report.untranslated.prefix(maximumListLength) {
                lines.append("  \(finding.file):\(finding.line)  [\(finding.language)]  \"\(escaped(finding.value))\"")
            }
            if report.untranslated.count > maximumListLength {
                lines.append("  … and \(report.untranslated.count - maximumListLength) more")
            }
            lines.append("")
        }

        if !report.bypasses.isEmpty {
            lines.append("note  localization bypasses (\(report.bypasses.count)):")
            for bypass in report.bypasses.prefix(maximumListLength) {
                lines.append("  \(bypass.file):\(bypass.line)  \(bypass.reason)")
                lines.append("      \(bypass.snippet)")
            }
            if report.bypasses.count > maximumListLength {
                lines.append("  … and \(report.bypasses.count - maximumListLength) more")
            }
            lines.append("")
        }

        for orphan in report.orphans where !orphan.keys.isEmpty {
            lines.append("note  keys not referenced in source — \(orphan.catalog) (\(orphan.keys.count)):")
            lines.append(contentsOf: list(orphan.keys, indent: "  "))
            lines.append("  Review before removing: keys built at runtime cannot be seen from source.")
            lines.append("")
        }

        if report.hasDynamicTables {
            lines.append("note  some calls compute their tableName, so table attribution is incomplete.")
            lines.append("")
        }

        lines.append(contentsOf: renderDiagnostics(report.diagnostics))
        lines.append("Scanned \(report.filesScanned) Swift file(s), \(report.stringsFound) user-visible string(s).")
        if report.testFilesSkipped > 0 {
            lines.append("Skipped \(report.testFilesSkipped) test file(s); test strings are not localized.")
        }
        // Saying so matters: these strings *are* localized, just not by
        // anything this tool audits, and a silent pass would read as coverage.
        if report.resolvedInLegacyStrings > 0 {
            lines.append(
                "\(report.resolvedInLegacyStrings) string(s) resolve to legacy .strings files "
                    + "(\(report.legacyStringsFiles) found) and are not checked."
            )
        }
        for path in report.templatesWritten {
            lines.append("Wrote \(path) — fill in each \"TODO\", then: xclocsmith add \(path)")
        }
        lines.append(summary(failures: report.failures, advisories: report.advisories))
        return lines.joined(separator: "\n")
    }

    // MARK: - writes

    public func render(_ report: WriteReport) -> String {
        var lines: [String] = []
        let prefix = report.dryRun ? "[dry run] " : ""

        let registered = report.count(.registered)
        let translated = report.count(.translated)
        let updated = report.count(.updated)
        let skipped = report.count(.skipped)
        let removed = report.count(.removed)

        var parts: [String] = []
        if registered > 0 { parts.append("\(registered) key(s) added") }
        if translated > 0 { parts.append("\(translated) translated") }
        if updated > 0 { parts.append("\(updated) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if parts.isEmpty { parts.append("no changes") }

        let language = report.language.map { " [\($0)]" } ?? ""
        lines.append("\(prefix)\(report.catalog)\(language): \(parts.joined(separator: ", "))")

        if removed > 0 {
            lines.append(contentsOf: list(report.changes.filter { $0.action == "removed" }.map(\.key), indent: "  "))
        }

        if !report.conflicts.isEmpty {
            lines.append("")
            lines.append("FAIL  \(report.conflicts.count) key(s) collide with an existing key by case:")
            for conflict in report.conflicts {
                lines.append("  \"\(escaped(conflict.key))\"  vs existing  \"\(escaped(conflict.existing))\"")
            }
            lines.append("  Xcode cannot generate symbols for both. Use the existing key, or rename one.")
        }

        if !report.refusals.isEmpty {
            lines.append("")
            lines.append("FAIL  \(report.refusals.count) key(s) not written:")
            let grouped = Dictionary(grouping: report.refusals, by: \.reason)
            for reason in grouped.keys.sorted() {
                lines.append("  \(reason):")
                lines.append(contentsOf: list((grouped[reason] ?? []).map(\.key), indent: "    "))
            }
        }
        return lines.joined(separator: "\n")
    }

    public func render(_ reports: LookupReports) -> String {
        var lines: [String] = []
        for report in reports.reports {
            lines.append("\"\(escaped(report.query))\"")
            if report.matches.isEmpty {
                lines.append("  no matches")
            }
            for match in report.matches {
                let similarity = match.similarity.map { "\($0)% " } ?? ""
                let translations = match.translations.isEmpty
                    ? "(no translation)"
                    : match.translations.sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: "   ")
                lines.append("  \(match.kind)  \(similarity)\"\(escaped(match.key))\"  → \(translations)")
                lines.append("      \(match.catalog)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - xcloc

    public func render(_ report: XclocCheckReport) -> String {
        var lines: [String] = []
        let language = report.targetLanguage ?? "unknown language"
        lines.append("\(report.bundle)  (\(language))")
        lines.append("  \(report.unitCount) unit(s), \(report.translatedCount) translated")
        lines.append("")

        if !report.metadataProblems.isEmpty {
            lines.append("FAIL  catalog metadata (\(report.metadataProblems.count)):")
            for problem in report.metadataProblems { lines.append("  \(problem)") }
            lines.append("")
        }

        if !report.formatMismatches.isEmpty {
            lines.append("FAIL  format specifiers disagree with the source (\(report.formatMismatches.count)):")
            for finding in report.formatMismatches.prefix(maximumListLength) {
                lines.append("  \(finding.file):\(finding.line)  \"\(escaped(finding.unitID))\"")
                lines.append("      \(finding.problem)")
            }
            lines.append("")
        }

        if !report.pluralGaps.isEmpty {
            lines.append("FAIL  incomplete plurals (\(report.pluralGaps.count)):")
            for finding in report.pluralGaps.prefix(maximumListLength) {
                lines.append("  \"\(escaped(finding.unitID))\" — \(finding.problem)")
            }
            lines.append("")
        }

        if !report.untranslated.isEmpty {
            lines.append("note  untranslated units (\(report.untranslated.count)):")
            lines.append(contentsOf: list(report.untranslated.prefix(maximumListLength).map(\.unitID), indent: "  "))
            lines.append("")
        }

        if !report.machineTranslated.isEmpty {
            lines.append("note  machine-translated units (\(report.machineTranslated.count)) — review before shipping:")
            lines.append(contentsOf: list(report.machineTranslated.prefix(maximumListLength).map(\.unitID), indent: "  "))
            lines.append("")
        }

        if !report.unsupportedUnits.isEmpty {
            lines.append("note  units this tool cannot apply (\(report.unsupportedUnits.count)):")
            for finding in report.unsupportedUnits.prefix(maximumListLength) {
                lines.append("  \"\(escaped(finding.unitID))\" — \(finding.problem)")
            }
            lines.append("")
        }

        if !report.unknownKeys.isEmpty {
            lines.append("note  units with no matching key in this project (\(report.unknownKeys.count)):")
            for finding in report.unknownKeys.prefix(maximumListLength) {
                lines.append("  \"\(escaped(finding.unitID))\" — \(finding.problem)")
            }
            lines.append("")
        }

        if !report.missingFromBundle.isEmpty {
            lines.append("note  catalog keys absent from this bundle (\(report.missingFromBundle.count)):")
            lines.append(contentsOf: list(report.missingFromBundle, indent: "  "))
            lines.append("")
        }

        lines.append(summary(failures: report.failures, advisories: report.advisories))
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    private func renderDiagnostics(_ diagnostics: [DiagnosticError]) -> [String] {
        guard !diagnostics.isEmpty else { return [] }
        var lines = ["FAIL  \(diagnostics.count) file(s) could not be read:"]
        for diagnostic in diagnostics {
            lines.append("  \(diagnostic.path): \(diagnostic.message)")
        }
        lines.append("")
        return lines
    }

    private func summary(failures: Int, advisories: Int) -> String {
        if failures == 0 && advisories == 0 { return "Clean." }
        if failures == 0 { return "\(advisories) advisory finding(s), nothing failing. Exit 0." }
        return "\(failures) failing finding(s), \(advisories) advisory. Exit 1."
    }
}
