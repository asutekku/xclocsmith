# xclocSmith

**A linter and editor for Xcode String Catalogs.**

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platform macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](https://developer.apple.com/macos/)
[![Licence MIT](https://img.shields.io/badge/Licence-MIT-blue.svg)](LICENSE)

Xcode will happily ship a Polish translation that dropped its `%@`, a Russian
plural missing `few` and `many`, and a `Text("Get Pro")` that no catalog has ever
heard of. `xclocsmith` finds all three in about a second, edits `.xcstrings`
files without destroying what Xcode put there, and closes the loop: it hands a
model exactly what is missing and then checks the answer.

It does Xcode localization and nothing else. No dependencies — `swift build` is
the whole install.

```console
$ xclocsmith check
App/Localizable.xcstrings  (Localizable, source en)
  123 keys, 123 translatable
  de: 123/123 (100%)
  ja: 120/123 (98%)  missing 3  unreviewed 1
  ru: 123/123 (100%)

  FAIL  missing ja translations (3):
    - Export Backup
    - Restore from Backup
    - Storage almost full

  FAIL  format specifiers disagree with the source string (1):
    - [ru] "Delete %@" has 0 format specifier(s), the source has 1
        "Delete %@"  →  "Удалить"

4 failing finding(s), 1 advisory. Exit 1.
```

## Installation

Requires macOS 13+ and a Swift 5.9 toolchain — Xcode 15 or newer, the same
requirement as `.xcstrings` itself.

```bash
git clone https://github.com/akko/xclocsmith
cd xclocsmith
swift build -c release
cp .build/release/xclocsmith /usr/local/bin/
```

Or run it from a checkout without installing: `swift run -c release xclocsmith check`.

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

## Translate with an LLM, and verify the result

Untranslated keys go out as a fill-in template and come back as a patch. The
point is the last step: **the tool checks what the model wrote.**

```bash
xclocsmith check --lang ru --out work.json   # every missing Russian string
#  … hand work.json to a model, or a translator …
xclocsmith add work.json                     # merged, never flattened
xclocsmith check --lang ru                   # exit 0 only if it is actually right
```

The template asks for the shape the *target language* needs, because nobody
should have to know that Russian takes four plural forms and Japanese one:

```json
{
  "format": "xclocsmith/v1",
  "catalog": "App/Localizable.xcstrings",
  "language": "ru",
  "strings": {
    "Delete %@": "TODO",
    "%lld items": {
      "source": "%lld items",
      "plural": { "one": "TODO", "few": "TODO", "many": "TODO", "other": "TODO" }
    },
    "notifications.label.favorite": {
      "source": "starred",
      "comment": "Tab label under the icon",
      "value": "TODO"
    }
  }
}
```

`source` and `comment` are read-only context and `add` ignores them. They matter
most on a project that keys by identifier: without the English beside it,
`notifications.label.favorite` asks for a translation of something nobody can
see. Keys that are already their own English string stay in the short
`"key": "TODO"` form.

The verify step catches what models actually get wrong: a dropped `%@`, a
Russian plural answered with one string. Both are silent in Xcode. `--json` on
every step means the loop needs no prose parsing; `scan --out` writes the same
kind of template for strings that are in no catalog yet; and `xcloc check`
applies the same scrutiny to an `.xcloc` bundle a vendor or an agent hands
back.

## Results on real projects

Nine open-source apps, `init && check && scan` with no hand-written config —
8,077 keys, 70 locales, 6,373 Swift files.

| Project | Catalogs · keys · locales | Broken format strings | Missing plural forms | Translated two ways | Hygiene | Duplicate strings ‡ | Unlocalized in code |
|---|---|---:|---:|---:|---:|---|---:|
| [Whisky](https://github.com/Whisky-App/Whisky) | 1 · 152 · 21 | 0 | 0 | **5** | **3** / 50 | 10 | 0 |
| [Loop](https://github.com/MrKai77/Loop) | 1 · 404 · 13 | 0 | 0 | **3** | **100** / 230 | 9 (+3 case) | 0 |
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | 9 · 472 · 1 | 0 | 0 | 0 | 0 | 0 (+4 case) | 85 |
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | 1 · 733 · 18 | **2** | **89** | **62** | **12** / 175 | 95 | 47 |
| [Mastodon for iOS](https://github.com/mastodon/mastodon-ios) | 9 · 980 · 53 | **9** | **53** | 0 | **66** / 271 | 122 | 27 |
| [HSTracker](https://github.com/HearthSim/HSTracker) | 23 · 777 · 13 | 0 | 0 | **5** | **2** / 45 | 64 (+1 case) | 10 |
| [Nimble Commander](https://github.com/mikekazakov/nimble-commander) | 54 · 1322 · 1 | 0 | **1** | **5** | **1** / 66 | 332 (+2 case) | 0 † |
| [GoMap](https://github.com/bryceco/GoMap) | 15 · 761 · 33 | **4** | **150** | **28** | **14** / 80 | 79 (+3 case) | 10 |
| [DuckDuckGo](https://github.com/duckduckgo/apple-browsers) | 19 · 2476 · 26 | **20** | **48** | **25** | **82** / 172 | 352 | 166 |

**Bold** ships as a user-visible bug; the hygiene column reads *failing / total*.
Mastodon's Albanian `"Option %ld"` is translated `"%ld nga %ld"`, which reads a
second argument the call never supplies. GoMap's Arabic translator pasted the
*description* of a string into two of its plural forms, and the count went with
it. Whisky renders one of its two "Remove" buttons as German `"Löschen"` —
delete — and the other as `"Entfernen"`.

The "translated two ways" column is the one nothing else finds. Two keys with
the same English are invisible in Xcode when a project keys by identifier, and
their translations drift apart. IceCubesApp has 62 such groups, including a key
whose English was changed to `"%lld posts"` and whose Belarusian still reads
`"%lld people talking"` — state `translated`, and detectable only beside its
twin. Mastodon's 122 duplicates all agree, because its translation memory
propagates them.

The failing half of the hygiene column is mostly one thing: a placeholder where
a translation should be. Whisky ships `config.notAvailable` as the literal
string "N/A" in Czech, French and Romanian; Loop's Arabic and Flemish write "-"
for sixty strings nobody has reached yet. Both read as translated in Xcode. The
rest of the column is punctuation, whitespace and Unicode — advisory, because it
is loud on any catalog with history behind it.

Whisky and Loop genuinely have no unlocalized strings, and the tool finds none
across their 213 files.

`check` tops out at 1.7s (Mastodon's 53 locales) and `scan` at 2.3s
(DuckDuckGo's 3,196 Swift files); everything else in the table takes a fraction
of a second. Both are cheap enough to run on every save.

Reproduce it with [`Scripts/corpus.sh`](Scripts/corpus.sh), which clones the
nine at the commits these numbers were measured against and prints the table.

‡ Exact duplicate groups *plus* near-duplicate pairs, so it includes the
"translated two ways" column rather than sitting beside it. For Nimble Commander
it is 260 near-duplicates and 72 exact groups.

† Nimble Commander is Objective-C++: 54 catalogs, three Swift files. `check` is
fully meaningful there, `scan` is not — Objective-C sources are not scanned at
all, which is the largest gap in this tool today.

## Commands

| Command | What it does | Writes? |
|---|---|---|
| `check` | Translation coverage and catalog health. | never |
| `scan` | Finds user-visible strings in source and checks them against the catalogs they reach. | never |
| `diff` | Finds translations stranded by a source-string change, against a git ref or between two files. | never |
| `lookup` | Finds existing keys, so a project does not grow three spellings of "Save". | never |
| `xcloc check` | Validates an `.xcloc` or `.xliff` before you import it. | never |
| `xcloc apply` | Imports an `.xcloc` or `.xliff` into your catalogs. | with `--apply` |
| `prune` | Removes keys no source references. | with `--apply` |
| `add` | Applies a payload of translations. | yes, `--dry-run` to preview |
| `set` | Sets one translation. | yes, `--dry-run` to preview |
| `init` | Writes `.xclocsmith.json`. | yes |

**Exit codes:** `0` clean, `1` findings, `2` usage or I/O error. An unknown
`--lang` fails the run instead of checking nothing and reporting clean.
`lookup` exits 1 when nothing matched; `prune` exits 2 when it refuses to act,
because a refusal needs a decision, not a fix.

Rules the CLI follows so automation cannot go wrong quietly:

- `xclocsmith <command> --help` lists exactly the flags that command accepts. A
  flag a command does not take is an error, never a silent no-op — and so is a
  value flag whose next argument is another flag, because `scan --out --json`
  is a forgotten filename, not a request for a file called `--json`.
- Every command that reports findings takes `--json` — everything but `init` —
  rendered from the same report object as the text output, so the two cannot
  drift. `failures` in the JSON equals the findings enumerated in it: fix
  everything in the payload and you reach exit 0.
- `--` ends flag parsing, so a key can be any string:
  `xclocsmith set -- "--odd key" "値"`.

## Checking catalogs

```bash
xclocsmith check
xclocsmith check --lang ja,de       # only these languages
xclocsmith check --strict           # advisories fail too
xclocsmith check --out work.json    # write a fill-in template for what is missing
```

Coverage is reported per language per catalog, with the outstanding keys named
rather than counted (lists truncate at 50). The counting follows Xcode's own
semantics: a `stringUnit` in state `new` is untranslated, `needs_review` is
reported separately, a `stale` key is on its way out and does not nag
translators, and a declared language with no entries yet shows 0% instead of
passing silently.

What fails the run:

- **Format specifiers that disagree with the source** — the classic localization
  crash, which no build step checks. Positional reordering (`%2$@ の %1$@`) is
  fine; substitutions (`%#@count@`) are expanded and checked through to the
  variations inside them, and so are plural forms — a German `other` that
  dropped its `%lld` is the single likeliest place for this bug to hide.
- **Incomplete plurals against real CLDR categories.** One filled row is
  complete for Japanese and three rows short for Russian; categories that only
  apply to decimals or compact millions (Czech `many`, French `many`) are not
  demanded. A flat translation of a pluralized key counts as incomplete too.
- **Keys that differ only in case**, which break Xcode's symbol generation.
- **Hygiene defects that lose text**: a "-" or "N/A" standing in for a
  translation nobody wrote, invisible and bidi-control characters, broken
  Markdown, mismatched line-break counts.
- **Glossary violations**, if you declare terms — a glossary is a decision you
  wrote down, so breaking it fails rather than advises.

What is advisory: one source string translated more than one way — "Free" the
price and "Free" the vacancy are one English string with two right answers, so
record reviewed pairs in `ignoreSimilar` — plus near-duplicates compared on the
*strings* rather than the keys, translations identical to the source, and the
softer hygiene rules: punctuation compared by class (`。`, `؟` and Greek `;`
satisfy their Latin equivalents), edge whitespace, doubled words (reduplicating
languages like Vietnamese are exempt), `...` where the typographic ellipsis
belongs, and two or more specifiers with no argument position — which no
translation can reorder, so write `%1$@`, `%2$@`.

## Scanning your source

```bash
xclocsmith scan
xclocsmith scan --files Sources/View.swift # report on one file, read all of them
```

Strings your code shows but never localizes, found by tokenizing Swift — with
escapes, raw strings, multi-line literals and interpolation — rather than
matching lines.

```console
$ xclocsmith scan
FAIL  strings not in a catalog (2):
  App/SettingsView.swift:7  [Toggle]  "Export Backup"
      → App/Localizable.xcstrings
  App/SettingsView.swift:6  [Button]  "Scan Storage"
      → App/Localizable.xcstrings

note  localization bypasses (1):
  App/Legacy.swift:5  .text = "…" needs String(localized:) to localize
      titleLabel.text = "Welcome back"

note  keys not referenced in source — App/Localizable.xcstrings (1):
  - Retired string
  Review before removing: keys built at runtime cannot be seen from source.

Scanned 2 Swift file(s), 3 user-visible string(s).
2 failing finding(s), 2 advisory. Exit 1.
```

**Recognized:** SwiftUI initializers and modifiers, `String(localized:)`,
`AttributedString(localized:)`, `LocalizedStringResource`, `NSLocalizedString` —
and your own APIs. `"Save".localized` is matched by name (`localizedAccessors`
in the config); a wrapper function is found by *reading its body* — if its first
parameter reaches a localization API, it localizes, while a function merely
named `localize` does not qualify. Likewise your own views: if `StatRow` renders
its `label` through `LocalizedStringKey`, then `StatRow(label: "Best Drop")` is
a key, and the same parameter name on a type that does not localize it stays
quiet.

Partial arguments count — `Text(flag ? "Yes" : "No")` is two keys,
`Text("Hello \(name)")` is matched against `"Hello %@"` — and tables resolve at
the call site, so `Text("Failed", tableName: "Errors")` is checked against
`Errors.xcstrings` even when the key exists in some other table.

**Bypasses** are advisories: `Text(verbatim:)`, string concatenation, UIKit
`label.text =` and `setTitle(_:)` — all of which display text no catalog will
translate. Test code is not scanned, and keys still living in a `.strings` file
are counted as localized, not reported.

**Keys nothing references** feed `prune`. Deleting is irreversible, so the check
is deliberately hard to satisfy: a key survives if it is mentioned anywhere in
the Swift text, a XIB, plist, storyboard, `.strings` or JSON file.
`InfoPlist.xcstrings`, `AppShortcuts.xcstrings` and Interface Builder keys like
`3aJ-8X-AqP.title` are exempt entirely.

## The project around the catalogs

Two checks that need more than a catalog to answer, which is why nothing else
runs them. Both ship as a user in some language reading English.

**Info.plist strings that reach no catalog.** DuckDuckGo declares
`NSLocalNetworkUsageDescription` in its Info.plist and in none of its
`InfoPlist.xcstrings`, so that permission prompt is English for every
non-English user. Both places a modern project can declare these are read — the
`Info.plist` file and the `INFOPLIST_KEY_…` build settings Xcode generates it
from — and only permission descriptions and `CFBundleDisplayName` count, because
`CFBundleName` is `$(PRODUCT_NAME)` almost everywhere.

**Catalogs shipping fewer languages than their neighbours.** iOS resolves a
language per *bundle*, not per app: an `Errors.xcstrings` with twelve languages
beside a `Localizable.xcstrings` with twenty means eight locales get a
translated interface and English error messages. Each catalog looks complete on
its own, and Xcode never puts them side by side. GoMap's GPX widget carries ten
fewer languages than the app around it.

## Adopting it on a project that already ships

A mature catalog has hundreds of findings. There is no version of "fix these
first" that ends with the check switched on, so the check never gets switched
on, and the next defect arrives unnoticed.

```bash
xclocsmith check --update-baseline   # accept what is there today
xclocsmith check --baseline          # fails only on what is new
```

Whisky goes from 68 failing and 512 advisory findings to clean; adding one key
with a dropped `%@` puts it back to failing. The file is sorted, readable JSON
rather than hashes — deleting a line un-suppresses a finding, and a pull request
diff says which string stopped being accepted. There are no globs and no
wildcards: every entry names one finding, so nothing is silenced by accident.

Entries that match nothing are reported too. A baseline nobody prunes stops
being a ratchet and becomes a drawer.

## Reviewing a change

```bash
xclocsmith diff HEAD                         # every catalog, against a commit
xclocsmith diff old.xcstrings new.xcstrings  # two files, no git involved
```

The finding this exists for is a **source string that changed while its
translations did not**. Xcode marks translations `needs_review` when *it*
notices the source move — but only for edits made in its own editor. A string
changed by a merge, a script, an `add` or a hand edit leaves every translation
underneath reading `translated` and saying the wrong thing. `git diff` shows
the English line changing; it cannot tell you which of the nineteen
translations below it were left behind. IceCubesApp's stranded Belarusian in
the table above is exactly this, caught here at the commit that introduces it
instead of years later. The report names the stranded languages and suggests
`set --state needs_review`; added and removed keys are notes, and only
stranded translations fail.

## Editing catalogs

```bash
xclocsmith add translations.json           # a payload, one catalog and language
xclocsmith set "Save" "保存" --lang ja
xclocsmith prune                           # report unreferenced keys
xclocsmith prune --apply
```

Files are written byte-for-byte in Xcode's own format, so an edit produces a
one-line diff instead of reordering the whole catalog. `add` and `set` merge
into the existing structure and refuse, rather than silently flatten, when a
localization holds plural variations or substitutions:

```
FAIL  1 key(s) not written:
  holds substitutions (%#@name@ arguments); pass --flatten to overwrite:
    - Found %#@count@
```

Refusals carry their reason, because "not in the catalog" and "would destroy
plural variations" call for different fixes. The other guards:

- Keys differing only by case are refused — Xcode cannot generate symbols for
  both — including two such keys inside a single payload.
- `set` will not create a key that is not already in the catalog without
  `--create`, so a typo cannot quietly add one. Writing a language the catalog
  has never seen requires `--add-language`, and the error suggests the code you
  probably meant.
- `prune` refuses to remove more than a quarter of a catalog without `--force`,
  and never writes anything if any catalog trips that guard.
- Duplicate keys, canonically-equivalent keys (NFC vs NFD) and malformed numbers
  are rejected on read rather than "repaired" by dropping one.

The `add` payload is the filled-in template from `check --out`. Beyond plain
`"key": "value"` pairs it takes a per-key `state` and `comment`, and a `plural`
object for variations. `"TODO"` values are left alone, so a template can be
filled in over several passes; a bare `{"key": "value"}` object also works,
with `--lang` and the catalog from the command line; `-` reads from stdin.

## Localization catalogs (`.xcloc`)

When a vendor or an agent returns an Xcode Localization Catalog, the risky
moment is the import: `xcodebuild -importLocalizations` warns about
untranslated files, but it does not compare format specifiers, so a `%@` where
your code passes an integer goes straight into the app.

```bash
xclocsmith xcloc check ja.xcloc      # validate before importing — reads only
xclocsmith xcloc apply ja.xcloc --apply
```

`xcloc check` reports format specifiers in each `<target>` against its
`<source>`, plural units missing the categories the target language requires,
`contents.json` and the XLIFF disagreeing about the target language,
machine-translated units (`state-qualifier="leveraged-mt"`, which Xcode's agent
workflow writes), units whose key is in none of your catalogs, and catalog keys
the bundle omits. A bare `.xliff` works too, since localizers often return one.

`xcloc apply` is `-importLocalizations` without a project or a build: it routes
each `<file>` element to the catalog for its table, merges into the existing
structure, and maps XLIFF states onto catalog states — machine translation is
always imported as `needs_review`, whatever the XLIFF claims. It will not
invent keys (an XLIFF translates a catalog, it does not extend one) and it will
not guess at a variation it does not recognize; both are reported and skipped.

## Configuration

`.xclocsmith.json`, found by walking up from the working directory. Everything
is optional; `xclocsmith init` writes one.

```json
{
  "targets": [
    {
      "name": "App",
      "sources": ["App", "Packages/DesignSystem"],
      "catalogs": ["App/Localizable.xcstrings", "App/Errors.xcstrings"]
    }
  ],
  "languages": ["ja", "de"],
  "excludePaths": ["**/Generated/*.swift"],
  "ignoreStrings": ["debug-only string"],
  "ignoreSimilar": [["Max Temperature", "Min Temperature"]],
  "glossary": {
    "Onsen": { "ja": "温泉", "de": "Onsen" },
    "Furolog": { "*": "Furolog" }
  },
  "localizableParams": ["captionKey"]
}
```

| Key | Meaning |
|---|---|
| `targets` | What compiles into what. `sources` are files that ship in this target; its `catalogs` must contain their strings. |
| `referenceSources` | Scanned only to decide whether a key is still used. Put shared packages here when you are not sure which targets compile them. |
| `inferred` | Written by `init` when a target was guessed from the directory layout. While present, a key found in another target's catalog for the same table counts. Delete it once the sources really are that target's. |
| `languages` | Languages to check, even if the catalog has no entries for one yet. |
| `excludePaths` | Glob patterns against repo-relative paths. |
| `ignoreStrings` | Literal values `scan` should never report. |
| `ignoreSimilar` | Acknowledged near-duplicate pairs, and duplicate source strings you have decided to keep. |
| `glossary` | Terms whose translation is fixed. `"*"` applies to every language; a named language overrides it, and a regional code inherits its base (`pt-BR` follows `pt` unless it says otherwise). |
| `localizedAccessors` | Members that localize the literal they are on. Defaults to `localized`, `localizedString`, `localizedValue`, `loc`, `l10n`. |
| `localizableCalls`, `localizableModifiers`, `localizableParams` | Extra contexts to treat as user-visible. |
| `skipCalls`, `skipParams` | Contexts to treat as internal. These win over the built-in tables. |
| `similarityThreshold` | Near-duplicate threshold, 50–99 (default 85). |
| `scanPreviews` | Report strings inside `#Preview` bodies (default `false`). |

In source, two directives override any of it:

```swift
Text("Debug only")        // xclocsmith:ignore
// xclocsmith:ignore-file  ← anywhere in a file, skips the whole file
```

## Continuous integration

String Catalogs need a Swift toolchain, so this wants a macOS runner.

```yaml
jobs:
  localization:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: swift build -c release --package-path Tools/xclocsmith
      - run: Tools/xclocsmith/.build/release/xclocsmith check --format github
      - run: Tools/xclocsmith/.build/release/xclocsmith scan --format github
```

`check`, `scan`, `diff` and `xcloc check` take `--format github`, which
annotates the PR diff, and `--format sarif`, which GitHub code scanning
ingests. Both point at the line a key is declared on rather than at the top of
a four-thousand-line catalog, and every finding carries a stable rule id —
`missing-translation`, `format-mismatch`, `divergent-translation`,
`string-not-in-catalog` and so on — so a filter written against one keeps
working. Failures are SARIF `error`, advisories `warning`; `--strict` fails on
advisories too. Exit code 2 always means misconfiguration, never findings, so a
script can tell the two apart.

## Editor and commit hooks

`scan --files` reports on the files you name while still reading the whole
project — whether `L("Take a bath")` is a localization call depends on a
`func L` declared in some other file, so a linter that reads one file in
isolation both misses real findings and invents fake ones. Fast enough to run
on every save, on every project in the table above.

Two ready hooks are in [`Examples/hooks/`](Examples/hooks):

- **`pre-commit`** — checks the staged Swift and catalogs, nothing else.
  `ln -s ../../Examples/hooks/pre-commit .git/hooks/pre-commit`.
- **`claude-code-hook.py`** — a Claude Code `PostToolUse` hook. When an agent
  writes a Swift file it hears about strings that reach no catalog; when it
  writes a catalog, about broken format specifiers, case collisions and a
  string it just gave a second translation. Exit 2 hands the message back to
  the model, so it fixes what it wrote instead of hearing about it at review
  time.

Neither hook asks about translation coverage: a string added in this edit has
no Japanese yet and is not supposed to.

## MCP server

`xclocsmith-mcp` speaks the Model Context Protocol over stdio. The reason to
prefer it over shelling out is permission granularity: the reading tools and
the writing tools are separate, annotated tools, so a host can grant one set
and confirm the other.

```json
{
  "mcpServers": {
    "xclocsmith": { "command": "/usr/local/bin/xclocsmith-mcp" }
  }
}
```

| Tool | Reads | Writes |
|---|---|---|
| `check_catalogs`, `scan_sources`, `lookup_keys`, `xcloc_check` | ✔ | — |
| `add_translations`, `set_translation`, `xcloc_apply` | ✔ | on request |
| `prune_catalogs` | ✔ | on request, and marked destructive |

Every tool takes an absolute `projectRoot`, because an MCP server has no
working directory. Writing tools default to reporting — `prune_catalogs` and
`xcloc_apply` do nothing until `apply: true`, and `add_translations` /
`set_translation` accept `dryRun` — and results carry the same report the CLI's
`--json` emits. The server is hand-written JSON-RPC over the package's own JSON
layer, so installing it is still just `swift build`.

## Out of scope

- **Producing `.xcloc` bundles** — `xcodebuild -exportLocalizations` builds your
  project to gather strings from storyboards, Info.plist and asset catalogs,
  which no linter should try to reproduce.
- **`.strings` / `.stringsdict` migration** — Xcode's migrator owns this. Such
  files are only ever read as reference text, never rewritten.
- **Compiling catalogs or generating symbols** — that is `xcstringstool`. This
  tool validates *against* the symbol rules; it never emits symbols.
- **Storyboard and XIB string extraction**, and **translation quality** — not a
  localization linter's job.

One real limitation: keys assembled at runtime (`"\(prefix).title"`) cannot be
seen from source. They are why `prune` reports before it writes, and why you
should read its list rather than trusting it.

## Contributing

`swift test` runs everything — 272 tests. The suite is the specification for
what counts as a user-visible string: `ClassifierTests` is a table of Swift
snippets and the keys Xcode would extract from them, and `RecallTests` holds
the idioms real projects use. A change to detection behaviour belongs there
first.

## Licence

MIT. See [LICENSE](LICENSE).
