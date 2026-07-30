# xclocSmith

**A linter and editor for Xcode String Catalogs.**

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platform macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](https://developer.apple.com/macos/)
[![Licence MIT](https://img.shields.io/badge/Licence-MIT-blue.svg)](LICENSE)

Xcode will happily ship a Polish translation that dropped its `%@`, a Russian
plural missing `few` and `many`, and a `Text("Get Pro")` that no catalog has ever
heard of. `xclocsmith` finds all three in about a second, and edits `.xcstrings`
files without destroying what Xcode put there.

It does Xcode localization and nothing else.

```console
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

## Features

- **Catches what Xcode cannot.** Format specifiers that disagree with their
  source string, plural categories CLDR requires, translations identical to the
  English, keys that differ only in case.
- **Reads your Swift, not your line endings.** A real tokenizer, so escapes,
  raw strings, multi-line literals, interpolation and a `)` inside a block
  comment inside an interpolation all parse correctly.
- **Learns your project's conventions.** `"Save".localized` and
  `String.localizedString("Add Card", comment: "")` are localization APIs if
  your project defines them — found by reading the function body, not by
  guessing from its name.
- **Edits without collateral damage.** Byte-identical to Xcode's own writer, so
  a one-key change is a one-line diff. Refuses to flatten plural variations or
  substitutions unless you ask.
- **Imports `.xcloc` bundles safely**, comparing format specifiers first —
  something `xcodebuild -importLocalizations` does not do.
- **Built for automation.** `--json` on every command, meaningful exit codes,
  and an MCP server whose read and write tools are separately permissioned.
- **No dependencies.** `swift build` is the whole install.

## Results on real projects

Nine open-source apps, `init && check && scan` with no hand-written config —
8,077 keys, 70 locales, 6,368 Swift files.

| Project | Catalogs · keys · locales | Broken format strings | Missing plural forms | Duplicate strings | Unlocalized in code |
|---|---|---:|---:|---|---:|
| [Whisky](https://github.com/Whisky-App/Whisky) | 1 · 152 · 21 | 0 | 0 | 8 | 0 |
| [Loop](https://github.com/MrKai77/Loop) | 1 · 404 · 13 | 0 | 0 | 9 (+3 case) | 0 |
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | 9 · 472 · 1 | 0 | 0 | 0 (+4 case) | 85 |
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | 1 · 733 · 18 | **2** | **33** | 91 | 47 |
| [Mastodon for iOS](https://github.com/mastodon/mastodon-ios) | 9 · 980 · 53 | **7** | **11** | 139 | 27 |
| [HSTracker](https://github.com/HearthSim/HSTracker) | 23 · 777 · 13 | 0 | 0 | 78 (+1 case) | 10 |
| [Nimble Commander](https://github.com/mikekazakov/nimble-commander) | 54 · 1322 · 1 | 0 | 0 | 323 (+2 case) | 0 |
| [GoMap](https://github.com/bryceco/GoMap) | 15 · 761 · 33 | **2** | 0 | 94 (+3 case) | 10 |
| [DuckDuckGo](https://github.com/duckduckgo/apple-browsers) | 19 · 2476 · 26 | **20** | 0 | 523 | 166 |

**Bold** ships as a user-visible bug — Mastodon's Albanian `"Option %ld"` is
translated `"%ld nga %ld"`, reading a second argument the call never supplies,
and its Russian plurals leave `other` empty, which renders as nothing for any
fractional count. Whisky and Loop have no unlocalized strings at all, across 213
files: the tool reports zero when zero is the answer.

`check` runs in under a second on eight of the nine — DuckDuckGo's 2,476 keys
across 19 catalogs take 1.7s. `scan` is under five seconds everywhere except
DuckDuckGo, whose 3,196 Swift files take 62s.

## Contents

- [Installation](#installation)
- [Getting started](#getting-started)
- [Commands](#commands)
- [Checking catalogs](#checking-catalogs)
- [Scanning your source](#scanning-your-source)
- [Editing catalogs](#editing-catalogs)
- [Localization catalogs (`.xcloc`)](#localization-catalogs-xcloc)
- [Configuration](#configuration)
- [Continuous integration](#continuous-integration)
- [Agents and automation](#agents-and-automation)
- [MCP server](#mcp-server)
- [Out of scope](#out-of-scope)

## Installation

Requires macOS 13+ and a Swift 5.9 toolchain — Xcode 15 or newer, the same
requirement as `.xcstrings` itself.

```bash
git clone https://github.com/akko/xclocsmith
cd xclocsmith
swift build -c release
cp .build/release/xclocsmith /usr/local/bin/
```

Or run it from a checkout without installing:

```bash
swift run -c release xclocsmith check
```

## Getting started

```bash
cd path/to/your/app
xclocsmith init      # writes .xclocsmith.json describing your project
xclocsmith check     # translation coverage and catalog health
xclocsmith scan      # strings in your code that no catalog knows about
```

`init` is optional — without a config the project is discovered from its layout.
Write one when you want to name your targets, pin the language list, or teach
the scanner about your own view types.

Both `check` and `scan` exit **1** when they find something, so they gate CI
directly. Neither writes a file unless you ask it to.

## Commands

| Command | What it does | Writes? |
|---|---|---|
| `check` | Translation coverage and catalog health. | never |
| `scan` | Finds user-visible strings in source and checks them against the catalogs they reach. | never |
| `lookup` | Finds existing keys, so a project does not grow three spellings of "Save". | never |
| `xcloc check` | Validates an `.xcloc` or `.xliff` before you import it. | never |
| `xcloc apply` | Imports an `.xcloc` or `.xliff` into your catalogs. | with `--apply` |
| `prune` | Removes keys no source references. | with `--apply` |
| `add` | Applies a payload of translations. | yes, `--dry-run` to preview |
| `set` | Sets one translation. | yes, `--dry-run` to preview |
| `init` | Writes `.xclocsmith.json`. | yes |

`xclocsmith <command> --help` lists exactly the flags that command accepts — a
flag one command takes and another does not is an error, never a silent no-op.

**Exit codes:** `0` clean, `1` findings, `2` usage or I/O error. A
misconfiguration never masquerades as a finding: an unknown `--lang` fails the
run rather than quietly checking nothing.

## Checking catalogs

```bash
xclocsmith check
xclocsmith check --lang ja,de       # only these languages
xclocsmith check --strict           # advisories fail too
xclocsmith check --json
```

**Coverage that reflects how Xcode actually works.** A `stringUnit` in state
`new` is untranslated, not done. A key marked `stale` is on its way out of the
catalog, so it is reported separately instead of nagging translators. A language
you declared but have not started shows 0%, rather than passing silently because
the catalog has no entries for it yet.

**Plurals against real CLDR categories.** "One filled row" is complete for
Japanese and three rows short for Russian. Categories that only apply to
decimals or compact millions (Czech `many`, French `many`) are not demanded.

```
FAIL  incomplete plural variations (1):
  - [ru] "%lld items" needs few, many, other
```

**Format specifiers**, the classic localization crash, which nothing in Xcode
warns you about:

```
FAIL  format specifiers disagree with the source string (1):
  - [ca] "instance.list.posts-%@" has 0 format specifier(s), the source has 1
      "%@ posts"  →  "% publicacions"
```

Positional reordering (`%2$@ の %1$@`) is understood — that is what positional
specifiers are for. Substitutions (`%#@count@`) are expanded and checked through
to the variations inside them.

**Near-duplicates and case variants.** Compared on the *strings*, not the keys,
so a project that keys by identifier gets a real answer rather than a list of
every sibling in every namespace.

## Scanning your source

```bash
xclocsmith scan
xclocsmith scan --json --out work.json     # findings plus a fill-in template
```

Strings your code shows but never localizes, found by tokenizing Swift rather
than matching lines.

**Recognized:** SwiftUI initializers and modifiers, `String(localized:)`,
`AttributedString(localized:)`, `LocalizedStringResource`, `NSLocalizedString`,
and your own views — if `StatRow` takes a `String` and renders it through
`LocalizedStringKey`, then `StatRow(label: "Best Drop")` is a key. The same
parameter name on a type that does *not* localize it stays quiet.

**Your own localization API, too.** Most projects older than String Catalogs
wrap the platform call, and some localize entirely through the wrapper:

```swift
"Save Deck".localized                                  // an extension you wrote
String.localizedString("Add Card", comment: "")        // a function you wrote
```

The extension is matched by name (`localizedAccessors` in the config). The
function is found by *reading its body*: if its first parameter reaches
`NSLocalizedString`, `String(localized:)` or `LocalizedStringResource`, it
localizes. A function merely named `localize` does not qualify.

**Partial arguments count too:**

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

**Not scanned:** test code — anything importing XCTest or Swift Testing, plus
the fixtures beside it. And keys still living in a `.strings` file are counted,
not reported: they are localized, just not by anything this tool audits.

**Keys nothing references**, with `prune` to remove them. Deleting a key is
irreversible, so this check is deliberately hard to satisfy: a key survives if
it is mentioned anywhere in the Swift text, in a XIB, plist, storyboard,
`.strings` or JSON — not only where the classifier could attribute it.
`InfoPlist.xcstrings` and `AppShortcuts.xcstrings` are exempt entirely, and so
are Interface Builder keys like `3aJ-8X-AqP.title`, which name an object inside
a nib and can never appear in code.

## Editing catalogs

```bash
xclocsmith add translations.json           # a payload, one catalog and language
xclocsmith set "Save" "保存" --lang ja
xclocsmith prune                           # report unreferenced keys
xclocsmith prune --apply
```

`add` and `set` merge into the existing structure. They refuse, rather than
silently flatten, when a localization holds plural variations or substitutions:

```
FAIL  1 key(s) not written:
  holds substitutions (%#@name@ arguments); pass --flatten to overwrite:
    - Found %#@count@
```

Refusals carry their reason, because "not in the catalog" and "would destroy
plural variations" call for different fixes.

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
- Duplicate keys, canonically-equivalent keys (NFC vs NFD) and malformed numbers
  are rejected on read rather than "repaired" by dropping one of them.

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

## Localization catalogs (`.xcloc`)

When a vendor or an agent returns an Xcode Localization Catalog, the risky moment
is the import: `xcodebuild -importLocalizations` warns about untranslated files,
but it does not compare format specifiers, so a `%@` where your code passes an
integer goes straight into the app.

```bash
xclocsmith xcloc check ja.xcloc      # validate before importing — reads only
xclocsmith xcloc apply ja.xcloc      # report what it would import
xclocsmith xcloc apply ja.xcloc --apply
```

`xcloc check` reports:

- format specifiers in each `<target>` that disagree with its `<source>`;
- plural units missing the categories the target language requires;
- `contents.json` and the XLIFF disagreeing about the target language;
- machine-translated units (Xcode's agent workflow marks them
  `state-qualifier="leveraged-mt"`) so they can be reviewed before shipping;
- units whose key is in none of your catalogs, and catalog keys the bundle omits.

`xcloc apply` is `-importLocalizations` without a project or a build. It routes
each `<file>` element to the catalog for its table — Xcode names them
`[table].strings` even when the strings came from a `.xcstrings` — merges into
the existing structure rather than replacing it, and maps XLIFF states onto
catalog states. Machine translation is imported as `needs_review` whatever its
state claims, because one marked `translated` is one nobody looks at again.

Two things it will not do: **invent keys** (an XLIFF translates a catalog, it
does not extend one) and **guess at a variation it does not recognise**. Both are
reported and skipped. A bare `.xliff` works too, since localizers often return
just that.

## Configuration

`.xclocsmith.json`, found by walking up from the working directory. Everything is
optional. `xclocsmith init` writes one.

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
| `inferred` | Written by `init` when a target was guessed from the directory layout. While it is present, a key found in another target's catalog for the same table counts. Delete it once the sources really are that target's. |
| `languages` | Languages to check. A language listed here is checked even if the catalog has no entries for it yet. |
| `excludePaths` | Glob patterns against repo-relative paths. |
| `ignoreStrings` | Literal values `scan` should never report. |
| `ignoreSimilar` | Acknowledged near-duplicate pairs. |
| `localizedAccessors` | Members that localize the literal they are on. Defaults to `localized`, `localizedString`, `localizedValue`, `loc`, `l10n`. |
| `localizableCalls`, `localizableModifiers`, `localizableParams` | Extra contexts to treat as user-visible. |
| `skipCalls`, `skipParams` | Contexts to treat as internal. These win over the built-in tables, so a project with its own non-localizing `Label` type can silence it. |
| `similarityThreshold` | Near-duplicate threshold, 50–99. |
| `scanPreviews` | Report strings inside `#Preview` bodies (default `false`). |

Classification order, which is the specification rather than an accident of the
code: a literal nested in an interpolation is a value; `verbatim:` is a bypass;
your `skipParams`/`skipCalls` win next; then a localizing member on the literal;
then the built-in localization APIs; then UIKit assignments; then parameters
your project declares, checked against the declaring type; then
`localizableParams`.

In source, two directives override any of it:

```swift
Text("Debug only")        // xclocsmith:ignore
// xclocsmith:ignore-file  ← anywhere in a file, skips the whole file
```

## Continuous integration

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

## Agents and automation

Every command that produces findings takes `--json` (all but `init`), rendered
from the same report as the human output, so the two cannot disagree. For
`check`, `scan`, `prune` and `xcloc`, `failures` equals the number of findings
enumerated in the payload — fix everything in the JSON and you reach exit 0.

```bash
xclocsmith scan --json | jq '.missingKeys[] | {value, file, line, catalog}'
```

The full loop needs no prose parsing:

```bash
xclocsmith scan --json --out work.json     # report to stdout, fill-in template to work.json
# fill in each "TODO" in work.json
xclocsmith add work.json --json            # the template names its own catalog and language
xclocsmith check --json                    # verify
```

Rules the CLI follows so automation cannot go wrong quietly:

- A flag a command does not accept is an error, not a no-op. `add --dry-run`
  does a dry run; it never writes while pretending to preview.
- `check`, `scan`, `prune`, `xcloc check` and `xcloc apply` write nothing unless
  you pass `--out`, `--template` or `--apply`. `add` and `set` are the write
  commands: they write by default and preview with `--dry-run`.
- A value flag whose next argument is another flag is an error. `scan --out
  --json` is a forgotten filename, and swallowing it would create a file called
  `--json`.
- `lookup` exits 1 when nothing matched, so it can gate a script.
- `prune` exits 2 when it refuses to act, because a refusal needs a decision,
  not a fix.
- `--` ends flag parsing, so a key can be any string:
  `xclocsmith set -- "--odd key" "値"`.

## MCP server

`xclocsmith-mcp` speaks the Model Context Protocol over stdio, so an agent can
call the tools directly instead of shelling out and parsing output.

```json
{
  "mcpServers": {
    "xclocsmith": { "command": "/usr/local/bin/xclocsmith-mcp" }
  }
}
```

The reason to prefer it over the CLI is **permission granularity**. Anything that
can run `xclocsmith` in a shell can run `xclocsmith prune --apply --force`. Here
the reading tools and the writing tools are separate, annotated tools, so a host
can grant one set and confirm the other:

| Tool | Reads | Writes |
|---|---|---|
| `check_catalogs`, `scan_sources`, `lookup_keys`, `xcloc_check` | ✔ | — |
| `add_translations`, `set_translation`, `xcloc_apply` | ✔ | on request |
| `prune_catalogs` | ✔ | on request, and marked destructive |

Every tool takes an absolute `projectRoot`, because an MCP server has no working
directory. Writing tools default to reporting: `prune_catalogs` and `xcloc_apply`
do nothing until `apply: true`, and `add_translations`/`set_translation` accept
`dryRun`. Results carry both a readable summary and `structuredContent` holding
the same report the CLI's `--json` emits.

The server is hand-written JSON-RPC over the package's own JSON layer, so
installing it is still just `swift build`.

## Out of scope

- **Producing `.xcloc` bundles** — `xcodebuild -exportLocalizations` builds your
  project to gather strings from storyboards, Info.plist and asset catalogs too,
  which no linter should try to reproduce. Reading and applying a bundle is
  supported; creating one is Xcode's job.
- **`.strings` / `.stringsdict` migration** — Xcode's built-in migrator owns
  this. Such files are only ever read as reference text, never rewritten.
- **Compiling catalogs or generating symbols** — that is `xcstringstool compile`
  and `generate-symbols`. This tool validates *against* the symbol rules; it
  never emits symbols.
- **Storyboard and XIB string extraction** — a different extraction pipeline.
- **Translation quality or machine translation** — not a localization linter's
  job.

One real limitation: keys assembled at runtime (`"\(prefix).title"`) cannot be
seen from source. They are why `prune` reports before it writes, and why you
should read its list rather than trusting it.

## Contributing

`swift test` runs everything. The test suite is the specification for what
counts as a user-visible string — `ClassifierTests` is a table of Swift snippets
and the keys Xcode would extract from them, and `RecallTests` holds the idioms
real projects use. A change to detection behaviour belongs there first.

## Licence

MIT. See [LICENSE](LICENSE).
