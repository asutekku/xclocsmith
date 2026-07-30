# xclocSmith

A linter and editor for Xcode String Catalogs (`.xcstrings`). It finds strings your
app shows but never localizes, translations that are missing or wrong, and keys
nothing uses any more — and it edits catalogs without destroying what Xcode put
there.

It does Xcode localization and nothing else.

```
$ xclocsmith scan
FAIL  strings not in a catalog (2):
  App/SettingsView.swift:110  [Label]  "Scan Storage"
      → App/Localizable.xcstrings
  App/Paywall.swift:45  [Text]  "Get Pro"
      → App/Localizable.xcstrings

note  localization bypasses (1):
  App/Legacy.swift:88  .text = "…" needs String(localized:) to localize
      titleLabel.text = "Welcome back"

Scanned 312 Swift file(s), 1584 user-visible string(s).
2 failing finding(s), 1 advisory. Exit 1.
```

## Install

Requires macOS 13+ and a Swift 5.9 toolchain (Xcode 15 or newer — the same
requirement as `.xcstrings` itself).

```bash
git clone https://github.com/akko/xclocsmith
cd xclocsmith
swift build -c release
cp .build/release/xclocsmith /usr/local/bin/
```

Or run it straight from a checkout without installing:

```bash
swift run -c release xclocsmith check
```

## Quick start

```bash
cd path/to/your/app
xclocsmith init      # writes .xclocsmith.json describing your project
xclocsmith check     # translation coverage and catalog health
xclocsmith scan      # strings in your code that no catalog knows about
```

Both `check` and `scan` exit **1** when they find something, so they gate CI
directly. Neither writes a file unless you ask it to.

## What it checks

**Coverage that reflects how Xcode actually works.** A `stringUnit` in state
`new` is untranslated, not done. A key marked `stale` is on its way out of the
catalog, so it is reported separately instead of nagging translators. A language
you declared but have not started shows 0%, rather than passing silently because
the catalog has no entries for it yet.

**Plurals against real CLDR categories.** "One filled row" is complete for
Japanese and three rows short for Russian. Categories that only apply to decimals
or compact millions (Czech `many`, French `many`) are not demanded.

```
FAIL  incomplete plural variations (1):
  - [ru] "%lld items" needs few, many, other
```

**Format specifiers.** A translation whose specifiers disagree with its key is
the classic localization crash, and nothing in Xcode warns you.

```
FAIL  format specifiers disagree with the source string (1):
  - [ja] "%lld items" specifier 1 is %lld in the source but %@ here
```

Positional reordering (`%2$@ の %1$@`) is understood — that is what positional
specifiers are for.

**Strings your code shows but never localizes**, found by tokenizing Swift
rather than matching lines. It understands escapes, multi-line literals, raw
strings, interpolation, and comments — including a `)` inside a block comment
inside an interpolation.

Recognized: SwiftUI initializers and modifiers, `String(localized:)`,
`AttributedString(localized:)`, `LocalizedStringResource`, `NSLocalizedString`,
and your own views — if `StatRow` takes a `String` and renders it through
`LocalizedStringKey`, then `StatRow(label: "Best Drop")` is a key. The same
parameter name on a type that does *not* localize it stays quiet.

A literal that is only part of an argument counts too:

```swift
Text(flag ? "Yes" : "No")     // both are keys
Text(name ?? "Unknown")       // so is this
Text("Hello \(name)")         // matched against the key "Hello %@"
```

**Tables.** `Text("Failed", tableName: "Errors")` is checked against
`Errors.xcstrings`. A key that exists in some other table is still missing from
the one the call asked for.

**Bypasses**, reported as advisories: `Text(verbatim:)`, string concatenation,
UIKit `label.text =` assignments and `setTitle(_:)` — all of which display text
that no catalog will ever translate.

**Keys nothing references**, with `prune` to remove them. `InfoPlist.xcstrings`
and `AppShortcuts.xcstrings` are exempt: their keys are plist keys and Siri
phrases, which never appear in source, and offering to delete
`NSCameraUsageDescription` would be a good way to lose your camera permission
string.

## Editing catalogs safely

`add` and `set` merge into the existing structure. They refuse, rather than
silently flatten, when a localization holds plural variations or substitutions:

```
FAIL  1 key(s) not written:
  - Found %#@count@
  These hold plural variations or substitutions. Edit them in Xcode, or pass --flatten.
```

Other guarantees:

- Keys differing only by case are refused, because Xcode cannot generate symbols
  for both — including two such keys inside a single payload.
- `set` will not create a key that is not already in the catalog unless you pass
  `--create`, so a typo cannot quietly add one.
- Writing a language the catalog has never seen requires `--add-language`, and
  the error suggests the code you probably meant.
- `prune` refuses to remove more than a quarter of a catalog without `--force`,
  and never writes anything if any catalog trips that guard.
- Files are written byte-for-byte in Xcode's own format, so an edit produces a
  one-line diff instead of reordering the whole catalog.
- Duplicate keys, canonically-equivalent keys (NFC vs NFD), and malformed
  numbers are rejected on read rather than "repaired" by dropping one of them.

## For agents

Every command takes `--json`, and the JSON is generated from the same report the
human output renders, so the two cannot disagree. `failures` always equals the
number of findings enumerated in the payload — an agent that fixes everything in
the JSON reaches exit 0.

```bash
xclocsmith scan --json | jq '.missingKeys[] | {value, file, line, catalog}'
```

The full loop needs no prose parsing:

```bash
xclocsmith scan --json --out work.json     # findings, plus a template of what is missing
# fill in each "TODO" in work.json
xclocsmith add work.json --json            # template names its own catalog and language
xclocsmith check --json                    # verify
```

Rules the CLI follows so automation cannot go wrong quietly:

- A flag a command does not accept is an error, not a no-op. `add --dry-run`
  does a dry run; it never writes while pretending to preview.
- Nothing is written unless you pass `--out`, `--template`, or `--apply`.
- `prune` reports by default and only writes with `--apply`.
- `lookup` exits 1 when nothing matched, so it can gate a script.
- Exit codes: **0** clean, **1** findings, **2** usage or I/O error. A
  misconfiguration never masquerades as a finding.
- `--` ends flag parsing, so a key can be any string: `xclocsmith set -- "--odd key" "値"`.

## Configuration

`.xclocsmith.json`, found by walking up from the working directory. Everything is
optional; without it the project is discovered. `xclocsmith init` writes one.

```json
{
  "targets": [
    {
      "name": "App",
      "sources": ["App", "Packages/DesignSystem"],
      "catalogs": ["App/Localizable.xcstrings", "App/Errors.xcstrings"]
    },
    {
      "name": "Watch",
      "sources": ["Watch"],
      "referenceSources": ["Packages/DesignSystem"],
      "catalogs": ["Watch/Localizable.xcstrings"]
    }
  ],
  "languages": ["ja", "de"],
  "excludePaths": ["**/Generated/*.swift"],
  "ignoreStrings": ["debug-only string"],
  "ignoreSimilar": [["Max Temperature", "Min Temperature"]],
  "localizableParams": ["captionKey"],
  "similarityThreshold": 85,
  "scanPreviews": false
}
```

| Key | Meaning |
|---|---|
| `targets` | What compiles into what. `sources` are files that ship in this target; its `catalogs` must contain their strings. |
| `referenceSources` | Scanned only to decide whether a key is still used. Put shared packages here when you are not sure which targets compile them: it prevents false orphans without demanding that every catalog carry every shared string. |
| `languages` | Languages to check. A language listed here is checked even if the catalog has no entries for it yet. |
| `excludePaths` | Glob patterns against repo-relative paths. |
| `ignoreStrings` | Literal values `scan` should never report. |
| `ignoreSimilar` | Acknowledged near-duplicate pairs. |
| `localizableCalls`, `localizableModifiers`, `localizableParams` | Extra contexts to treat as user-visible. |
| `skipCalls`, `skipParams` | Extra contexts to treat as internal. |
| `similarityThreshold` | Near-duplicate threshold, 50–99. |
| `scanPreviews` | Report strings inside `#Preview` bodies (default `false`). |

In source, two directives override any of it:

```swift
Text("Debug only")        // xclocsmith:ignore
// xclocsmith:ignore-file  ← anywhere in a file, skips the whole file
```

## CI

```yaml
- run: xclocsmith check
- run: xclocsmith scan
```

Use `--strict` to fail on advisories too (near-duplicate keys, bypasses,
unreferenced keys). Distinguish the exit codes if you want misconfiguration to
be louder than findings:

```bash
xclocsmith check --json > report.json
case $? in
  0) echo "clean" ;;
  1) echo "findings"; jq '.failures' report.json ;;
  2) echo "xclocsmith is misconfigured"; exit 2 ;;
esac
```

## Commands

| Command | What it does |
|---|---|
| `check` | Translation coverage and catalog health. Reads only. |
| `scan` | Finds user-visible strings in source and checks them against the catalogs they reach. |
| `prune` | Removes keys no source references. Reports unless `--apply`. |
| `add` | Applies a payload of translations. |
| `set` | Sets one translation. |
| `lookup` | Finds existing keys, so a project does not grow three spellings of "Save". |
| `init` | Writes `.xclocsmith.json`. |

`xclocsmith <command> --help` lists exactly the flags that command accepts.

### The `add` payload

```json
{
  "format": "xclocsmith/v1",
  "catalog": "App/Localizable.xcstrings",
  "language": "ja",
  "strings": {
    "Save": "保存",
    "Detailed": { "value": "詳細", "state": "needs_review", "comment": "Button" },
    "%lld items": { "plural": { "other": "%lld個" } }
  }
}
```

`"TODO"` values are left alone, so a template can be filled in over several
passes. A bare `{"key": "value"}` object also works, in which case `--lang` and
the catalog come from the command line. `-` reads the payload from stdin.

## Deliberately out of scope

- **`.xcloc` bundles, `xcodebuild -exportLocalizations`/`-importLocalizations`** —
  the translator round-trip is Xcode's, and it works.
- **`.strings` / `.stringsdict` migration** — Xcode's built-in migrator owns
  this. Such files are only ever read as reference text, never rewritten.
- **Compiling catalogs or generating symbols** — that is `xcstringstool compile`
  and `generate-symbols`. This tool validates *against* the symbol rules; it
  never emits symbols.
- **Storyboard and XIB string extraction** — a different extraction pipeline.
- **Translation quality or machine translation** — not a localization linter's job.

One real limitation: keys assembled at runtime (`"\(prefix).title"`) cannot be
seen from source. They are why `prune` reports before it writes, and why you
should read its list rather than trusting it.

## Contributing

`swift test` runs everything. The test suite is the specification for what
counts as a user-visible string — `ClassifierTests` is a table of Swift snippets
and the keys Xcode would extract from them. A change to detection behaviour
belongs there first.

## Licence

MIT. See [LICENSE](LICENSE).
