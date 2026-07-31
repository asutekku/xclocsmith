# Changelog

All notable changes to this project are documented here. This project follows [Semantic Versioning](https://semver.org).

## [0.1.1]

- `rename` gives a key a new name in the catalog and at every call site, for migrating off keys that are their own English sentence.
- `sentence-key`, an advisory check naming keys of five words or more that carry translations, ranked by what an edit would orphan.
- `translation_template`, a ninth MCP tool: an agent asks for the payload instead of assembling one from a coverage report.
- `localizedAccessors` is read from `.xclocsmith.json`. It was documented and honoured by the classifier, but never parsed.

## [0.1.0] — 2026-07-31

First release.

### Checking

- Coverage per catalog and language, following Xcode's own semantics: `new` counts as untranslated, `stale` keys are excluded and reported separately, `automatic` is modelled rather than read as absent, and a language declared in configuration is checked even when the catalog has no entries for it yet.
- Format specifiers compared between each key and its translations, including positional (`%1$@`) reordering, substitution (`%#@name@`) structure, and every value inside a plural variation.
- A translation that discarded the argument positions its source gave it fails the run. Same specifiers, same count, so Xcode compiles it — but they now bind in written order, and any reordering the sentence performs swaps the values.
- Plural completeness against CLDR cardinal categories per language, separating the categories ordinary integers reach from those that only apply to decimals or compact millions. A category standing for one known count is exempt from format comparison: English "%lld new post" is German "ein neuer Beitrag".
- Case-variant keys, failing hard only for manually-managed strings, which are the ones `xcstringstool generate-symbols` rejects.
- Duplicate source strings, grouped, naming the languages that translate them differently — visible only on catalogs keyed by identifier, where two keys can share an English string.
- Near-duplicate keys compared on the strings they render, filtering pairs that differ only in digits or one unrelated word.
- An opt-in glossary: term to per-language rendering, `*` for a rendering every language must use. Violations fail rather than advise.
- CLDR plural data for `an`, `ars`, `ckb`, `kmr` and `oc`.

### Translation hygiene

- Mechanical defects found by comparing each translation against its source: punctuation that disagrees, leading and trailing space, double spaces, line-break counts, zero-width and byte-order marks, bidirectional overrides and unclosed embeddings, U+FFFD, French non-breaking spaces, doubled words, broken Markdown, dropped `^[…](inflect: true)` markup, and every plural category filled with the same text.
- A dash or a "TODO" standing in for a translation is reported as a placeholder rather than as the punctuation defect it looks like.
- Two source-side rules: `...` where the typographic ellipsis belongs, and two or more specifiers with no argument position, which no translation can reorder.
- Punctuation is compared by class, so `。`, `؟`, `：` and `።` satisfy their Latin equivalents and Greek `;` answers an English `?`. Zero-width joiners are left alone for Persian and the Indic scripts, and reduplicating languages are exempt from the doubled-word rule.
- Findings that mean text was lost or markup broke fail; the rest advise.

### Scanning

- Swift tokenizer handling escapes, multi-line literals, raw strings, interpolation, and nested and block comments. Call sites are parsed forwards, so a literal inside a ternary or `??` is found.
- `String(localized:)`, `AttributedString(localized:)`, `LocalizedStringResource` and `NSLocalizedString` are first-class localization APIs, as is a member on the literal itself — `"Save".localized`.
- Project-defined localization functions are found by reading their bodies: a function whose first parameter reaches a localization API localizes, one merely named `localize` does not.
- Project-specific parameters are discovered from source and verified against the declaring type, so `StatRow(label:)` counts only if `StatRow` renders it through `LocalizedStringKey`.
- Interpolated literals are matched against the format keys they produce, and `tableName:` / `table:` resolves to the catalog the call actually reads.
- UIKit text assignments, `setTitle(_:)`, `Text(verbatim:)` and string concatenation are reported as bypasses.
- Test code is not scanned. Keys still kept in a `.strings` file are counted as localized rather than reported missing.
- `--files` narrows the report to named files while still reading the whole project, since whether a call localizes depends on declarations elsewhere. Orphans are not reported for a subset, and the run says so.
- Orphan detection is deliberately hard to satisfy: a key survives if it is mentioned in any Swift, XIB, plist, storyboard, `.strings` or JSON file. `InfoPlist.xcstrings`, `AppShortcuts.xcstrings` and Interface Builder keys are exempt entirely.
- `scan` runs in 2.0s on GoMap and 50s on DuckDuckGo's 4,673 files.

### The project around the catalogs

- Info.plist strings that reach no `InfoPlist.xcstrings`, read from both the plist file and the `INFOPLIST_KEY_…` build settings. Only permission descriptions and `CFBundleDisplayName` count.
- Catalogs shipping fewer languages than the project's other catalogs, which is invisible in Xcode because iOS resolves a language per bundle.
- The bundle's development region against each catalog's source language.

### Translating

- `check --out` and `scan --template` write a fill-in payload asking for the shape the *target* language needs — Russian's four plural forms, Japanese's one — one template per catalog and language.
- Templates carry the source string and the developer's comment as read-only context, so a project keyed by identifier does not ask for a translation of a string the translator has never seen.
- A flat translation of a pluralised key is reported as incomplete for any language requiring more than one form.
- [`Examples/translate.sh`](Examples/translate.sh) drives the whole loop across every language, re-prompting the model with the linter's findings when one fails.

### Editing

- Writes merge into the existing localization; plural variations and substitutions are never flattened without `--flatten`.
- Plural authoring from the `add` payload, and `"TODO"` values are left alone so a template can be filled in over several passes.
- Case-collision refusal, including within a single payload.
- `set` will not create keys without `--create`; unknown languages need `--add-language`.
- `prune` decides across all catalogs before writing anything, and refuses to remove more than a quarter of a catalog without `--force`.
- Output is byte-identical to Xcode's own formatting.

### Localization catalogs

- `xcloc check` validates an `.xcloc` bundle or bare `.xliff` before import: format specifiers against the source, plural completeness for the target language, machine-translated units, metadata disagreements, and units whose key is in no catalog.
- `xcloc apply` imports without a project or a build, routing each `<file>` element to its table's catalog, merging rather than replacing, and importing machine translation as `needs_review`.
- Never invents keys and never guesses at an unrecognised variation; both are reported and skipped.

### Reviewing

- `diff` compares catalogs against a git ref, or two files against each other, and reports source strings that changed while their translations did not — the case Xcode only marks `needs_review` for edits made in its own editor.
- Translations already marked `needs_review` are not reported again, and the git ref is verified before any file is read.

### Baselines

- `--update-baseline` records every current finding as accepted; `--baseline` reports only what is not in the file, so a project with history can turn the checks on today.
- Findings are identified by rule, file, subject and language — never by line, message or severity.
- The file is sorted readable JSON, one entry per finding, no globs. Entries matching nothing are reported so the file can be tightened.

### Output

- `--format sarif` (SARIF 2.1.0, for GitHub code scanning) and `--format github` (workflow commands, for inline pull-request annotations) on `check`, `scan`, `diff` and `xcloc check`.
- Both render from a flattened `Report.findings`, so the annotation count equals the reported finding count, and each finding carries a stable rule id.
- Catalog findings resolve to the line their key is declared on, so an annotation lands on the row rather than the top of the file.

### Interface

- `--json` on every command that reports findings, rendered from the same report as the text output.
- Per-command flag grammars: a flag a command does not accept is an error, and a value flag will not swallow a following flag as its value.
- `check`, `scan`, `prune` and `xcloc` write nothing without `--out`, `--template` or `--apply`; `add` and `set` write by default and preview with `--dry-run`.
- `--` ends flag parsing, so a key can be any string.
- Exit codes: 0 clean, 1 findings, 2 usage or I/O error.

### MCP

- `xclocsmith-mcp`, an stdio MCP server (protocol 2025-06-18) exposing eight tools over the same library the CLI uses.
- Reading and writing tools are separate and annotated (`readOnlyHint`, `destructiveHint`), so a host can grant the read-only half and confirm the rest.
- Results carry a readable summary and `structuredContent` holding the same report as `--json`.

### Configuration

- `.xclocsmith.json`, found by walking up from the working directory, describing targets, languages, exclusions, acknowledged near-duplicates, a glossary, and the project's own localization APIs. Everything is optional; without it the project is discovered from its layout.
- In-source `xclocsmith:ignore` and `xclocsmith:ignore-file` directives.

### Distribution

- No dependencies: the JSON, JSON-RPC and SARIF layers are written against the package's own types.
- A universal macOS binary on every tagged release, and a Homebrew tap, so CI needs no Swift toolchain.
