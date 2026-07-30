# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org).

## [0.1.0] — unreleased

First release.

### Checking

- Coverage per catalog and language, following Xcode's own semantics: `new`
  string units count as untranslated, `stale` keys are excluded from coverage
  and reported separately, and a language declared in configuration is checked
  even when the catalog has no entries for it yet.
- Plural completeness against CLDR cardinal categories per language, separating
  categories ordinary integers reach from those that only apply to decimals or
  compact millions.
- Format-specifier comparison between each key and its translations, including
  positional (`%1$@`) reordering and substitution (`%#@name@`) structure.
- Case-variant keys, with a hard failure only for manually-managed strings,
  which are the ones `xcstringstool generate-symbols` actually rejects.
- Near-duplicate key detection that filters out pairs differing only in digits
  or in one unrelated word.

### Scanning

- Swift tokenizer handling escapes, multi-line literals, raw strings,
  interpolation, and nested and block comments.
- Call sites parsed forwards, so a literal inside a ternary or `??` is found.
- `String(localized:)`, `AttributedString(localized:)`, `LocalizedStringResource`
  and `NSLocalizedString` treated as first-class localization APIs.
- Interpolated literals matched against the format keys they produce.
- `tableName:` / `table:` resolved to the catalog the call actually reads.
- Project-specific parameters discovered from source and verified against the
  declaring type.
- UIKit text assignments and `setTitle(_:)` reported as bypasses.
- `InfoPlist.xcstrings` and `AppShortcuts.xcstrings` exempt from source-reference
  checks.

### Editing

- Writes merge into the existing localization; plural variations and
  substitutions are never flattened without `--flatten`.
- Plural authoring from the `add` payload.
- Case-collision refusal, including within a single payload.
- `set` will not create keys without `--create`; unknown languages need
  `--add-language`.
- `prune` decides across all catalogs before writing anything, and refuses to
  remove more than a quarter of a catalog without `--force`.
- Output is byte-identical to Xcode's own formatting.

### Localization catalogs

- `xcloc check` validates an `.xcloc` bundle or bare `.xliff` before import:
  format specifiers against the source, plural completeness for the target
  language, machine-translated units, metadata disagreements, and units whose
  key is in no catalog.
- `xcloc apply` imports a bundle without a project or a build, routing each
  `<file>` element to its table's catalog, merging rather than replacing, and
  importing machine translation as `needs_review`.
- Never invents keys and never guesses at an unrecognised variation; both are
  reported and skipped.

### Fixed before release

Found by an independent audit of this code, each with a regression test:

- `prune` computed orphans per (target, catalog). A catalog shared by two
  targets — an app and its widget — saw every other target's keys as unused,
  and deleted live ones while reporting a different set. Orphans are now
  accumulated per catalog across every target that ships it.
- A plural payload overwrote a substitutions-based localization without
  `--flatten`, deleting the translator's sentence frame. `setPluralTranslation`
  is now guarded like `setTranslation`.
- Interpolated literals containing a literal `%` never matched their catalog
  key, because Xcode writes it `%%`. On a real project this was 8 of 14
  reported failures.
- `scan --lang <typo>` swallowed the unknown-language error and reported clean.
- `check --out` pooled every catalog and language into one template, so `add`
  then created keys in the wrong catalog. Templates are now one per
  (catalog, language).
- `let title = "…"` was reported as a UIKit `.title` assignment; an assignment
  target must now be a member access.
- `Button("cancel")` was dropped as identifier-shaped. That filter now applies
  only where the context is weak, never where a localization API is explicit.
- Multi-line interpolated literals produced no format pattern at all.

### Interface

- `--json` on every command, rendered from the same report as the text output.
- Per-command flag grammars: a flag a command does not accept is an error.
- Nothing is written without `--out`, `--template` or `--apply`.
- Exit codes: 0 clean, 1 findings, 2 usage or I/O error.
