<h1 align="center">xclocsmith</h1>

<p align="center">
  <b>A linter and editor for Xcode String Catalogs — and the loop that lets a model translate them.</b>
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-orange.svg" alt="Swift 5.9+"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg" alt="Platform macOS 13+"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/Licence-MIT-blue.svg" alt="Licence MIT"></a>
</p>

Xcode ships whatever is in your `.xcstrings`. A Polish string that lost its `%@`, a Russian plural missing `few`, a `Text("Get Pro")` no catalog has heard of — all of it compiles, and all of it reaches users. `xclocsmith` finds them in about a second.

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

No dependencies, no config required, and it writes Xcode's exact file format back.

## Install

```bash
brew install asutekku/tap/xclocsmith
```

A universal binary — no Swift toolchain, which is what makes it cheap on a CI runner. Needs macOS 13+; `.xcstrings` itself needs Xcode 15+.

<details>
<summary>Build from source instead</summary>

```bash
git clone https://github.com/asutekku/xclocsmith
cd xclocsmith
swift build -c release
cp .build/release/xclocsmith .build/release/xclocsmith-mcp /usr/local/bin/
```

Needs Swift 5.9. Or run it in place: `swift run -c release xclocsmith check`.
</details>

## Usage

```bash
cd path/to/your/app

xclocsmith check     # translation coverage and catalog health
xclocsmith scan      # user-visible strings in code that no catalog knows about
xclocsmith init      # optional — pins targets, languages and your own view types
```

Both `check` and `scan` exit `1` on findings and write nothing. Without a config, the project is discovered from its layout.

## What it finds

- **Broken format strings** — a translation that dropped, added or retyped a specifier.
- **Swapped arguments** — a translation that dropped the source's `%1$@` numbering, so its values now bind in written order. Never crashes. Always wrong.
- **Missing plural forms** — the categories *that* language requires, not the ones English has.
- **One English, two translations** — the same source string translated two different ways.
- **Placeholder translations** — `"N/A"`, `"-"`, `"TODO"` sitting in the catalog marked `translated`.
- **Strings that reach no catalog** — resolving `Text`, `LocalizedStringKey`, `String(localized:)` and your own wrappers.
- **Problems around the catalogs** — an unlocalized `Info.plist` prompt, or one bundle shipping fewer languages than its neighbour.
- **Keys that are English sentences** — reword one and every translation under it is orphaned, silently.

Details: [checking](docs/checking.md) · [scanning](docs/scanning.md) · [project checks](docs/project-checks.md)

## Translating with a model

A model can translate a catalog. What it cannot do is tell you it succeeded — a dropped `%@` is fluent, plausible output that compiles and ships. So the loop is built around the step after the translation.

```
xclocsmith check --out   →  what is missing, shaped for the target language
        ↓
     a model fills it in
        ↓
xclocsmith add           →  merged in, plurals intact, nothing else touched
        ↓
xclocsmith check         →  exit 0, or the findings go back to the model
```

```bash
xclocsmith check --lang ru --out work.json
cat work.json | your-model | xclocsmith add -
xclocsmith check --lang ru
```

[`Examples/translate.sh`](Examples/translate.sh) runs that across every language and re-prompts the model with the linter's own findings when one fails. Agents can skip the script: an [MCP server](docs/agents.md#mcp-server) exposes reading and writing as separately permissioned tools, and a [`PostToolUse` hook](docs/agents.md#editor-and-commit-hooks) catches a broken specifier while the agent still has the file open.

More: [translating](docs/translating.md) · [agents and automation](docs/agents.md)

## In CI

Annotates the pull request diff, and files the rest as code-scanning alerts on the line each key is declared.

```yaml
name: Localization
on: [push, pull_request]

jobs:
  xclocsmith:
    runs-on: macos-15
    permissions:
      contents: read
      security-events: write        # required by upload-sarif
    steps:
      - uses: actions/checkout@v4
      - run: brew install asutekku/tap/xclocsmith

      - run: xclocsmith check --format github
      - run: xclocsmith scan --format github

      - run: xclocsmith check --format sarif > localization.sarif
        if: always()
      - uses: github/codeql-action/upload-sarif@v3
        if: always()                # the steps above exit 1 on findings
        with:
          sarif_file: localization.sarif
```

Already shipping with a backlog? Take a [baseline](docs/ci.md#adopting-it-on-a-project-that-already-ships) and fail only on what you add next. More: [continuous integration](docs/ci.md).

## Results

Nine open-source apps, no hand-written config: 8,077 keys, 70 locales, 6,373 Swift files. A few of the findings, all shipping today:

- Mastodon's Albanian translates `"Option %ld"` as `"%ld nga %ld"` — a second argument the call never supplies.
- IceCubesApp changed a key's English to `"%lld posts"`; its Belarusian still reads `"%lld people talking"`, marked `translated`.
- Whisky renders one "Remove" button as German `"Löschen"` — delete — and the other as `"Entfernen"`.
- DuckDuckGo asks for local network access with a prompt that is English in every language.
- GoMap's GPX widget ships eleven fewer languages than the app beside it.

`check` tops out at 3.0s and `scan` at 2.6s on the largest project in the set. Full table and analysis: [results](docs/results.md), reproducible with [`Scripts/corpus.sh`](Scripts/corpus.sh).

## Commands

| Command | What it does | Writes |
|---|---|---|
| `check` | Translation coverage and catalog health. | never |
| `scan` | User-visible strings in source, and the catalogs they reach. | never |
| `diff` | Translations stranded by a source-string change. | never |
| `lookup` | Existing keys, so you don't grow three spellings of "Save". | never |
| `xcloc check` | Validates an `.xcloc` or `.xliff` before you import it. | never |
| `add` | Applies a payload of translations. | `--dry-run` to preview |
| `set` | Sets one translation. | `--dry-run` to preview |
| `prune` | Removes keys no source references. | needs `--apply` |
| `rename` | Renames a key in the catalog and at every call site. | needs `--apply` |
| `xcloc apply` | Imports an `.xcloc` or `.xliff`. | needs `--apply` |
| `init` | Writes `.xclocsmith.json`. | yes |

Exit codes: `0` clean, `1` findings, `2` usage or I/O error. Every reporting command takes `--json`, and an unknown flag is always an error, never a silent no-op.

## Documentation

| | |
|---|---|
| [Translating with a model](docs/translating.md) | The loop, the template format, and what the verify step catches. |
| [Checking catalogs](docs/checking.md) | Failing rules, advisories, argument order, `diff`. |
| [Scanning your source](docs/scanning.md) | What `scan` recognizes, bypasses, and unreferenced keys. |
| [Project checks](docs/project-checks.md) | Info.plist strings and per-bundle language gaps. |
| [Editing catalogs](docs/editing.md) | `add`, `set`, `prune`, `rename`, and `.xcloc` import. |
| [Configuration](docs/configuration.md) | `.xclocsmith.json` and in-source directives. |
| [Continuous integration](docs/ci.md) | GitHub annotations, SARIF, baselines. |
| [Agents and automation](docs/agents.md) | The CLI contract, hooks, and the MCP server. |
| [Results on real projects](docs/results.md) | The corpus table and analysis. |

## Out of scope

- **Producing `.xcloc` bundles** — that needs a build; `xcodebuild -exportLocalizations` owns it.
- **`.strings` / `.stringsdict` migration** — Xcode's migrator owns it. Read as reference, never rewritten.
- **Compiling catalogs or generating symbols** — that's `xcstringstool`. This validates *against* the symbol rules.
- **Storyboard extraction**, and **translation quality** — not a linter's job.

## Contributing

`swift test` runs everything — 330 tests. The suite doubles as the specification for what counts as a user-visible string: `ClassifierTests` is a table of Swift snippets and the keys Xcode would extract from them, `RecallTests` holds the idioms real projects use. Detection changes belong there first.

## Licence

MIT. See [LICENSE](LICENSE).
