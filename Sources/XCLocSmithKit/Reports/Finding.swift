import Foundation

/// One finding, flattened to what a machine reader needs: a rule, a severity,
/// a sentence, and somewhere to point.
///
/// The reports are shaped for the way people read them — coverage per language,
/// duplicates grouped by the string they share — and that shape is wrong for
/// GitHub and SARIF, which both want a flat list of things wrong at a location.
/// Flattening once, here, is what stops the annotation output and the terminal
/// output disagreeing about how many problems there are.
public struct Finding: Equatable, Sendable {
    public enum Level: String, Sendable {
        case error, warning, note
    }

    /// Stable identifier for the kind of defect. These are part of the tool's
    /// interface: a suppression or a code-scanning filter is written against
    /// them, so they change only in a major version.
    public let rule: String
    public let level: Level
    public let message: String
    /// Repo-relative, so the same string works as a SARIF artifact URI and as a
    /// GitHub annotation path.
    public let file: String?
    public let line: Int?
    /// The catalog key this is about, when it is about one. Carried separately
    /// from the message so a renderer can find the line the key is declared on;
    /// a catalog finding has no line until somebody goes looking for it.
    public let key: String?

    public init(
        rule: String,
        level: Level,
        message: String,
        file: String? = nil,
        line: Int? = nil,
        key: String? = nil
    ) {
        self.rule = rule
        self.level = level
        self.message = message
        self.file = file
        self.line = line
        self.key = key
    }
}

extension Report {
    /// Nothing by default: a report that names no defects — `lookup`, a dry-run
    /// write — has nothing to annotate, and should say so rather than invent a
    /// category.
    public var findings: [Finding] { [] }
}

// MARK: - check

extension CheckReport {
    public var findings: [Finding] {
        var findings: [Finding] = []

        for catalog in catalogs {
            let file = catalog.path

            for coverage in catalog.coverage where !coverage.isSourceLanguage {
                for key in coverage.missing {
                    findings.append(Finding(
                        rule: "missing-translation",
                        level: .error,
                        message: "\"\(key)\" has no \(coverage.language) translation.",
                        file: file,
                        key: key
                    ))
                }
                for key in coverage.empty {
                    findings.append(Finding(
                        rule: "empty-translation",
                        level: .error,
                        message: "\"\(key)\" has an empty \(coverage.language) translation.",
                        file: file,
                        key: key
                    ))
                }
                for key in coverage.needsReview {
                    findings.append(Finding(
                        rule: "needs-review",
                        level: .warning,
                        message: "\"\(key)\" is \(coverage.language) needs_review — machine translation, "
                            + "or a source string that changed after it was translated.",
                        file: file,
                        key: key
                    ))
                }
                for key in coverage.identicalToSource {
                    findings.append(Finding(
                        rule: "identical-to-source",
                        level: .warning,
                        message: "\"\(key)\" is identical in \(coverage.language) and the source language.",
                        file: file,
                        key: key
                    ))
                }
            }

            for gap in catalog.pluralGaps {
                findings.append(Finding(
                    rule: "plural-incomplete",
                    level: .error,
                    message: "\"\(gap.key)\" is missing the \(gap.language) plural "
                        + "\(gap.missingCategories.joined(separator: ", ")) "
                        + "\(gap.missingCategories.count == 1 ? "category" : "categories").",
                    file: file,
                    key: gap.key
                ))
            }

            for mismatch in catalog.formatMismatches {
                var message = "[\(mismatch.language)] \"\(mismatch.key)\" \(mismatch.problem)"
                if let source = mismatch.source, let translation = mismatch.translation {
                    message += " — \"\(source)\" → \"\(translation)\""
                }
                findings.append(Finding(
                    rule: "format-mismatch",
                    level: .error,
                    message: message,
                    file: file,
                    key: mismatch.key
                ))
            }

            for violation in catalog.glossaryViolations {
                findings.append(Finding(
                    rule: "glossary",
                    level: .error,
                    message: "[\(violation.language)] \"\(violation.term)\" must render as "
                        + "\"\(violation.expected)\", but \"\(violation.source)\" was translated "
                        + "\"\(violation.translation)\".",
                    file: file,
                    key: violation.key
                ))
            }

            for duplicate in catalog.caseDuplicates {
                findings.append(Finding(
                    rule: duplicate.breaksSymbolGeneration ? "case-collision" : "case-variant",
                    level: duplicate.breaksSymbolGeneration ? .error : .warning,
                    message: duplicate.breaksSymbolGeneration
                        ? "Keys differ only by case and both generate symbols: "
                            + duplicate.keys.joined(separator: " vs ")
                        : "Keys differ only by case: " + duplicate.keys.joined(separator: " vs "),
                    file: file,
                    key: duplicate.keys.first
                ))
            }

            // One finding per group, never per language: a string under three
            // keys that disagree in forty locales is one thing to fix, and
            // forty annotations on one line of one file is spam. It also keeps
            // the finding count equal to the advisory count.
            for duplicate in catalog.duplicateSources {
                guard let first = duplicate.divergences.first else {
                    findings.append(Finding(
                        rule: "duplicate-source",
                        level: .warning,
                        message: "\"\(duplicate.text)\" is the source string for "
                            + duplicate.keys.joined(separator: ", ") + ".",
                        file: file,
                        key: duplicate.keys.first
                    ))
                    continue
                }
                let renderings = first.renderings
                    .map { "\"\($0.value)\" (\($0.key))" }
                    .joined(separator: " vs ")
                let others = duplicate.divergences.count - 1
                let tail = others > 0
                    ? " (and \(others) more \(others == 1 ? "language" : "languages"))"
                    : ""
                findings.append(Finding(
                    rule: "divergent-translation",
                    level: .warning,
                    message: "\"\(duplicate.text)\" is translated more than one way in "
                        + "\(first.language): \(renderings)\(tail)",
                    file: file,
                    key: duplicate.keys.first
                ))
            }

            for pair in catalog.similarKeys {
                findings.append(Finding(
                    rule: "near-duplicate",
                    level: .warning,
                    message: "\(pair.percent)% similar: \"\(pair.aText ?? pair.a)\" (\(pair.a)) "
                        + "vs \"\(pair.bText ?? pair.b)\" (\(pair.b))",
                    file: file,
                    key: pair.a
                ))
            }

            for key in catalog.staleKeys {
                findings.append(Finding(
                    rule: "stale-key",
                    level: .note,
                    message: "\"\(key)\" is marked stale; Xcode no longer finds it in source.",
                    file: file,
                    key: key
                ))
            }
        }

        findings.append(contentsOf: diagnostics.map(\.finding))
        return findings
    }
}

// MARK: - scan

extension ScanReport {
    public var findings: [Finding] {
        var findings: [Finding] = []

        for missing in missingKeys {
            findings.append(Finding(
                rule: "string-not-in-catalog",
                level: .error,
                message: "\"\(missing.value)\" is shown to the user but is in no catalog "
                    + "(expected in \(missing.catalog)).",
                file: missing.file,
                line: missing.line
            ))
        }
        for finding in untranslated {
            findings.append(Finding(
                rule: "untranslated-string",
                level: .error,
                message: "\"\(finding.value)\" has no \(finding.language) translation "
                    + "in \(finding.catalog).",
                file: finding.file,
                line: finding.line
            ))
        }
        for bypass in bypasses {
            findings.append(Finding(
                rule: "localization-bypass",
                level: .warning,
                message: "\(bypass.reason): \(bypass.snippet)",
                file: bypass.file,
                line: bypass.line
            ))
        }
        for orphan in orphans {
            for key in orphan.keys {
                findings.append(Finding(
                    rule: "orphaned-key",
                    level: .warning,
                    message: "\"\(key)\" is in the catalog but nothing in source references it.",
                    file: orphan.catalog,
                    key: key
                ))
            }
        }
        findings.append(contentsOf: diagnostics.map(\.finding))
        return findings
    }
}

// MARK: - xcloc check

extension XclocCheckReport {
    public var findings: [Finding] {
        // An XLIFF finding already knows its file and line inside the bundle,
        // which is where somebody reviewing an import wants to be sent.
        func flatten(_ items: [XclocFinding], rule: String, level: Finding.Level) -> [Finding] {
            items.map { item in
                Finding(
                    rule: rule,
                    level: level,
                    message: "\"\(item.unitID)\" \(item.problem)",
                    file: item.file,
                    line: item.line
                )
            }
        }
        return flatten(formatMismatches, rule: "format-mismatch", level: .error)
            + flatten(pluralGaps, rule: "plural-incomplete", level: .error)
            + flatten(unknownKeys, rule: "unknown-key", level: .warning)
            + flatten(unsupportedUnits, rule: "unsupported-unit", level: .warning)
            + flatten(untranslated, rule: "untranslated-string", level: .warning)
            + flatten(machineTranslated, rule: "machine-translated", level: .warning)
            + metadataProblems.map {
                Finding(rule: "bundle-metadata", level: .error, message: $0, file: bundle)
            }
            + missingFromBundle.map {
                Finding(
                    rule: "missing-from-bundle",
                    level: .warning,
                    message: "\"\($0)\" is in the catalog but not in this bundle.",
                    file: bundle
                )
            }
    }
}

extension DiagnosticError {
    var finding: Finding {
        Finding(rule: "configuration", level: .error, message: message, file: path)
    }
}
