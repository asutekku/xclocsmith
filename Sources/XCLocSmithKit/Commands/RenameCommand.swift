import Foundation

/// Gives a key a new name, in the catalog and at every call site.
///
/// This exists for one migration: a project keyed by its English sentences.
/// There the key *is* the content, so rewording the sentence renames the key,
/// and a rename is indistinguishable from a delete plus an add — every
/// translation underneath is orphaned rather than flagged, and `diff` reports
/// one key added, one removed, and exits 0. Under an identifier key the same
/// edit changes a value, which `diff` catches and fails on.
///
/// Doing it by hand is where translations actually get lost, which is why this
/// refuses far more often than it acts.
public struct RenameCommand {
    public struct Options {
        public var apply: Bool
        /// Rewrite the Swift call sites as well as the catalog.
        public var updateSources: Bool

        public init(apply: Bool = false, updateSources: Bool = true) {
            self.apply = apply
            self.updateSources = updateSources
        }
    }

    private let workspace: Workspace
    private let options: Options

    public init(workspace: Workspace, options: Options) {
        self.workspace = workspace
        self.options = options
    }

    public func run(from oldKey: String, to newKey: String, catalogPath: String?) throws -> RenameReport {
        guard !oldKey.isEmpty, !newKey.isEmpty else {
            throw SmithError.usage("both the old and the new key are required")
        }
        guard oldKey != newKey else {
            throw SmithError.usage("the old and new keys are the same")
        }

        var report = RenameReport(oldKey: oldKey, newKey: newKey, applied: options.apply)

        // Which catalog. Ambiguity is refused rather than guessed: renaming the
        // wrong file's key is not something a later run can detect.
        let candidates: [Catalog]
        if let catalogPath {
            guard let catalog = workspace.catalog(at: catalogPath) else {
                throw SmithError.usage("cannot read catalog \(catalogPath)")
            }
            guard catalog.strings[oldKey] != nil else {
                throw SmithError.usage("\"\(oldKey)\" is not a key in \(catalog.displayPath)")
            }
            candidates = [catalog]
        } else {
            candidates = workspace.allCatalogs().filter { $0.strings[oldKey] != nil }
            guard !candidates.isEmpty else {
                throw SmithError.usage("\"\(oldKey)\" is not a key in any catalog")
            }
            guard candidates.count == 1 else {
                let names = candidates.map(\.displayPath).sorted().joined(separator: ", ")
                throw SmithError.usage(
                    "\"\(oldKey)\" is in \(candidates.count) catalogs (\(names)); name the one to rename in"
                )
            }
        }

        var catalog = candidates[0]
        report.catalog = catalog.displayPath

        // Case-only differences break Xcode's symbol generation, and the whole
        // point of this command is to leave a project in better shape.
        if let clash = catalog.keys.first(where: { $0 != oldKey && $0.lowercased() == newKey.lowercased() }) {
            throw SmithError.usage(
                "\"\(newKey)\" differs only by case from the existing key \"\(clash)\", "
                    + "which breaks symbol generation"
            )
        }

        report.movesEnglishIntoCatalog = !catalog.hasSourceText(oldKey)
        report.languagesCarried = catalog.languages
            .filter { $0 != catalog.sourceLanguage && catalog.localization(oldKey, $0) != nil }
            .sorted()

        if options.updateSources {
            report.sourceEdits = try sourceEdits(for: oldKey, in: catalog)
        }

        guard options.apply else { return report }

        try catalog.rename(oldKey, to: newKey)
        try catalog.save()

        // Sources after the catalog: a half-applied rename that has moved the
        // key is recoverable by hand, one that has rewritten call sites
        // pointing at a key that does not exist yet is a broken build.
        for (file, edits) in Dictionary(grouping: report.sourceEdits, by: \.file) {
            try rewrite(file: file, edits: edits, newKey: newKey)
        }
        return report
    }

    // MARK: - Sources

    /// Every call site that resolves to this key in this catalog's table.
    ///
    /// Found through the scanner rather than by searching for the text, so a
    /// string that merely *contains* the key, or one belonging to a different
    /// table, is not touched. The offsets come from re-lexing the file: the
    /// scanner reports a line, and the lexer says exactly where the literal
    /// starts and ends, including its raw-string hashes.
    private func sourceEdits(for key: String, in catalog: Catalog) throws -> [RenameReport.SourceEdit] {
        // A catalog source code cannot name — InfoPlist, AppShortcuts — has no
        // call sites to rewrite, and matching one against the default table
        // would rewrite Localizable's.
        guard let table = catalog.kind.tableName else { return [] }
        let found = try ScanCommand(
            workspace: workspace,
            options: .init()
        ).occurrences()
        let occurrences = found.filter {
            $0.value == key && ($0.table ?? "Localizable") == table
        }
        guard !occurrences.isEmpty else { return [] }

        var edits: [RenameReport.SourceEdit] = []
        for (file, hits) in Dictionary(grouping: occurrences, by: \.file) {
            // Findings carry the repo-relative path they are reported under;
            // reading and rewriting need the real one.
            let absolute = workspace.configuration.absolute(file)
            guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else {
                throw SmithError.usage("cannot read \(file)")
            }
            let lexed = SwiftLexer.lex(text)
            for hit in hits {
                let matches = lexed.literals.filter {
                    $0.value == key && $0.line == hit.line && !$0.isNested
                }
                // An interpolated or multi-line literal is not a plain key that
                // can be swapped for another; and a line the lexer cannot match
                // means the file changed under us. Either way, say so rather
                // than edit approximately.
                guard let literal = matches.first, matches.count == 1,
                      !literal.hasInterpolation, !literal.isMultiline else {
                    edits.append(RenameReport.SourceEdit(
                        file: file,
                        line: hit.line,
                        context: hit.context,
                        start: 0,
                        end: 0,
                        skipped: matches.isEmpty
                            ? "no plain literal on this line to rewrite"
                            : "the literal is interpolated, multi-line, or appears more than once"
                    ))
                    continue
                }
                edits.append(RenameReport.SourceEdit(
                    file: file,
                    line: hit.line,
                    context: hit.context,
                    start: literal.contextStart,
                    end: literal.end,
                    skipped: nil
                ))
            }
        }
        return edits.sorted {
            $0.file == $1.file ? $0.line < $1.line : $0.file < $1.file
        }
    }

    /// Replaces the literals in one file, back to front so earlier offsets stay
    /// valid as the text shifts underneath them.
    private func rewrite(file: String, edits: [RenameReport.SourceEdit], newKey: String) throws {
        let applicable = edits.filter { $0.skipped == nil }.sorted { $0.start > $1.start }
        guard !applicable.isEmpty else { return }
        let absolute = workspace.configuration.absolute(file)
        guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else {
            throw SmithError.usage("cannot read \(file)")
        }
        var characters = Array(text.utf8)
        let replacement = Array(("\"" + escapeForSwift(newKey) + "\"").utf8)
        for edit in applicable {
            guard edit.start >= 0, edit.end <= characters.count, edit.start < edit.end else {
                throw SmithError.usage("\(file):\(edit.line) moved while renaming; nothing was written to it")
            }
            characters.replaceSubrange(edit.start..<edit.end, with: replacement)
        }
        guard let rewritten = String(bytes: characters, encoding: .utf8) else {
            throw SmithError.usage("rewriting \(file) produced invalid UTF-8; it was left alone")
        }
        do {
            try rewritten.write(toFile: absolute, atomically: true, encoding: .utf8)
        } catch {
            throw SmithError.cannotWrite(path: file, reason: error.localizedDescription)
        }
    }

    /// A Swift string literal body. Identifier keys need none of this; a key
    /// that does is exactly the key somebody should be migrating away from, and
    /// it still has to round-trip correctly on the way.
    func escapeForSwift(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\0": result += "\\0"
            default: result.append(character)
            }
        }
        return result
    }
}
