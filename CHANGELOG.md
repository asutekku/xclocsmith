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
- Duplicate source strings, grouped, with the languages that translate them
  differently named. Only visible on catalogs keyed by identifier, where two
  keys can share an English string; exact matches carry no minimum length,
  since the strings most likely to be entered twice are the short ones.
- An opt-in glossary: term to per-language rendering, `*` for a rendering every
  language must use. Violations fail rather than advise, because a glossary is
  a decision the project wrote down.
- `extractionState: automatic`, which Xcode writes and DuckDuckGo ships, is
  modelled rather than read as an absent state.
- CLDR plural data for `an`, `ars`, `ckb`, `kmr` and `oc`, which real catalogs
  in the sample ship and which previously fell back to `other` alone.

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
- `--files` narrows the report to named files while still reading the whole
  project, since whether a call localizes depends on declarations elsewhere.
  Orphans are not reported for a subset, and the run says so.

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

### MCP

- `xclocsmith-mcp`, an stdio MCP server (protocol 2025-06-18) exposing eight
  tools over the same library the CLI uses.
- Reading and writing tools are separate and annotated (`readOnlyHint`,
  `destructiveHint`), so a host can grant the read-only half and confirm the
  rest — a distinction a shell cannot make.
- Results carry a readable summary and `structuredContent` holding the same
  report as `--json`.
- No dependencies: the JSON-RPC layer is written against the package's own JSON
  types.

### Interface

- `--json` on every command that reports findings, rendered from the same report
  as the text output.
- Per-command flag grammars: a flag a command does not accept is an error.
- `check`, `scan`, `prune` and `xcloc` write nothing without `--out`,
  `--template` or `--apply`; `add` and `set` write by default and preview with
  `--dry-run`.
- Exit codes: 0 clean, 1 findings, 2 usage or I/O error.

### Fixed after running against five shipping projects

IceCubesApp, Mastodon for iOS, Whisky, Loop and damus. Each fix has a regression
test built from the catalog that exposed it.

- `%arg` — the token for a substitution's own argument — parsed as `%a` plus
  `rg`. Hex float is gone from the grammar; it has no place in UI text.
- `%#@name@` was not counted as consuming the argument its substitution
  declares, so every substitution-based translation looked like it had dropped
  all of them. Arguments consumed inside a substitution's variation values were
  invisible for the same reason.
- Plural categories were compared against the flat source rather than their
  counterpart. English "1 new post" is German "Ein neuer Beitrag": the singular
  spells the number out and carries no specifier, correctly.
- Translations were compared against the key rather than the source-language
  value, so a project keying by identifier had every string checked against
  something no user sees. Together these four accounted for 270 of the 272
  format mismatches first reported on IceCubesApp.
- Near-duplicate detection compared keys, not the strings they render. On
  Mastodon that reported 554 pairs of deliberately distinct siblings and hid the
  real finding: 139 English strings entered under more than one key.
- `scan` demanded a catalog entry for `Text("\(name)")`, which extracts to the
  key `"%@"` — a string `check` already classifies as untranslatable. The filter
  now judges the extracted key rather than the source text, and `ignoreStrings`
  applies to interpolated literals for the first time.
- Discovery walked into `.xcloc` bundles and treated the catalog copies under
  `Source Contents` as project catalogs, so a `.strings`-based project appeared
  to have three targets pointing at an export artifact.
- Discovery could emit two targets with the same name, leaving `--target` unable
  to address either.
- A parameter name from the built-in list overrode direct evidence about a
  project's own type, so `PEError(message:)` was reported as a display string.
- A variation gap the source language shares — a device variation with no
  `other` case — was reported once per language, sending every translator after
  a defect only the source can fix.
- `--` did not stop `--help` detection: `xclocsmith set -- "--help" "値"`
  printed the help page and wrote nothing.
- A value flag swallowed a following flag as its value, so `scan --out --json`
  wrote a file named `--json`.

### Fixed after running against nine shipping projects

IceCubesApp, Mastodon for iOS, NetNewsWire, Whisky, Loop, HSTracker, GoMap,
Nimble Commander and DuckDuckGo — 8,077 keys, 70 locales, 6,368 Swift files.
The theme is reading each project's own conventions instead of assuming Apple's.

**Recall — strings the scan could not see at all.** These are the dangerous
ones: the output looked clean.

- Project-defined localization functions are now found by reading their bodies.
  A function whose first parameter reaches `NSLocalizedString`,
  `String(localized:)` or `LocalizedStringResource` localizes; one merely named
  `localize` does not. HSTracker localizes entirely through
  `String.localizedString(_:comment:)` at 293 call sites — the scan saw 32
  user-visible strings in 1,041 files, and now sees 2,104.
- `"Save".localized` — a member accessed on the literal — is a localization API.
  It is checked before the bypass rules, so
  `label.stringValue = "Quit".localized` is localized, not a bypass.

**Precision — findings that were never real.**

- Every source file was checked against every inferred target's catalogs, so a
  string present in one was reported missing from all the others. GoMap went
  from 4,401 unlocalized strings to 10. Discovery also no longer invents a
  target per catalog directory when they all compile the same sources, and
  `.lproj` is treated as a resource folder rather than a target boundary.
- Keys still kept in `.strings` are localized, just not by this tool; they are
  counted and named rather than reported missing. On DuckDuckGo that was 20,323
  of 29,932 findings.
- Test code is not scanned. DuckDuckGo's `expectation(description:)` and its
  fixture builders were 6,140 findings on their own.
- `description:`, `header:` and `footer:` left the default parameter-name list.
  No AppKit, UIKit or SwiftUI API takes display text under those labels —
  SwiftUI's `header:`/`footer:` are `@ViewBuilder` — while
  `XCTestExpectation(description:)` and `TextTableColumn(header:)` do. Whisky's
  entire unlocalized column was three CLI table headers.
- `DispatchQueue(label:)`, `@available(message:)` and other identifier-shaped
  arguments are skipped, as is `message:` on a call whose name says it logs.
- A concatenated fragment is a bypass and nothing else. It has no catalog key to
  be missing, and asking a translator to add `"Are you sure you want to delete "`
  is worse than useless.

**Orphans — keys offered for deletion that were live.**

- Interface Builder keys (`3aJ-8X-AqP.title`) name an object inside a nib and
  can never appear in code, so they are exempt like `InfoPlist.xcstrings`.
- Evidence is pooled across inferred targets: HSTracker keeps its catalogs under
  `Translations/` and its code elsewhere, so nothing the code proved ever
  reached them. 515 keys were offered for deletion; now 92.
- A key mentioned anywhere in the Swift text survives, even where the classifier
  could not attribute it. Being wrong here costs a translator's work.

**Performance.** `scan` on GoMap went from 4m 23s to 2.0s, and on DuckDuckGo's
4,673 files from 2m 30s to 50s. The orphan check searched with Foundation's
canonical, locale-aware `String.contains`, which is grapheme-by-grapheme; it now
uses a literal byte search. Format-key resolution caches its compiled patterns
and each catalog's candidate keys.

### Translate-and-verify loop

- A template asks for the plural forms the *target* language needs — Russian's
  four, Japanese's one — instead of a flat `"TODO"` that gives no hint the key
  is pluralised at all.
- A flat translation of a pluralised key is reported as incomplete for any
  language that requires more than one form. It used to count as 100% complete,
  which is exactly what happens when a model is handed a bare `"TODO"`.

### Fixed after an independent audit of this code

- **Format specifiers were never compared inside plural variations.** The walk
  that collects comparable values descended into the `stringUnit` object rather
  than stopping at the category holding it, so nothing under `variations` was
  ever collected. A German `other` form that had dropped its `%lld` reported
  clean — and a plural is the likeliest place in a catalog for a lost count.
  Fixing it found four more real bugs in the corpus, including GoMap's Arabic
  translator having pasted the *description* of a string into two of its plural
  forms.
- A category standing for one known count is exempt from that comparison.
  English "%lld new post" is German "ein neuer Beitrag" and Arabic
  "بقي تكرار واحد"; comparing those was 60 of the first 62 findings the fix
  produced.
- **Templates carry the source string and the developer's comment.** They used
  to carry the key and `"TODO"` and nothing else, so on a project keyed by
  identifier the flagship workflow asked for a translation of a string the
  translator had never seen. Both fields are read-only and `add` ignores them.

### Tests

150, including a CLI suite covering flag grammar, exit codes, `--json` shape and
byte-identical trees after reading commands, and a recall suite built from the
call sites and templates the sample projects exposed.
