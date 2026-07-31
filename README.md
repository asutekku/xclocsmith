<h1 align="center">xclocSmith</h1>

<p align="center">
  <b>A linter and editor for Xcode String Catalogs —<br>
  and the verification loop that lets a model translate them.</b>
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-orange.svg" alt="Swift 5.9+"></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg" alt="Platform macOS 13+"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/Licence-MIT-blue.svg" alt="Licence MIT"></a>
</p>

Xcode will happily ship a Polish translation that dropped its `%@`, a Russian plural missing `few` and `many`, and a `Text("Get Pro")` that no catalog has ever heard of. `xclocsmith` finds all three in about a second, and edits `.xcstrings` files without destroying what Xcode put there.

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

It does Xcode localization and nothing else. No dependencies — `swift build` is the whole install.

## Features

- **[Translate with a model, and prove it worked.](docs/translating.md)** `check --out` writes exactly what is missing in the shape the *target* language needs, `add` merges the reply without flattening a plural, and `check` runs again — so a machine translation only lands if it survives the linter. [One script](Examples/translate.sh) drives the whole loop across every language and re-prompts the model with the findings when it fails.
- **[Give an agent the tools instead.](docs/agents.md)** An [MCP server](docs/agents.md#mcp-server) exposes reading and writing as separately permissioned tools, and a [`PostToolUse` hook](docs/agents.md#editor-and-commit-hooks) tells an agent it just wrote a string no catalog knows about, or broke a format specifier — while it is still holding the file, not at review time.
- **[Check catalogs](docs/checking.md)** for the defects Xcode compiles anyway: format specifiers that disagree with the source, plurals missing the categories that language actually requires, keys differing only in case, placeholders standing in for translations, glossary violations, and one English string quietly translated two different ways. Including [the one that never crashes](docs/checking.md#argument-order) — a translation that dropped the source's `%1$@` numbering and now prints two values the wrong way round.
- **[Scan your source](docs/scanning.md)** for user-visible strings that reach no catalog — resolving `LocalizedStringKey`, `String(localized:)`, `Text`, your own wrapper functions and the table each one lands in.
- **[Check the project around the catalogs](docs/project-checks.md)** — an untranslated `Info.plist` permission prompt, a development region that is not the source language, one catalog shipping fewer languages than its neighbours. iOS resolves a language per bundle, and each file looks complete on its own.
- **[Edit catalogs](docs/editing.md)** — `add`, `set`, `prune` — writing Xcode's exact format back, so the diff is your change and nothing else. [Validate an `.xcloc` or `.xliff`](docs/editing.md#localization-catalogs-xcloc) before importing it — it compares format specifiers against the source, which Xcode's own import does not.
- **[Review a change](docs/checking.md#reviewing-a-change-diff)** — `diff` finds translations stranded by an edit to the English, against a git ref or between two files.
- **[Gate CI](docs/ci.md)** — SARIF and GitHub annotations on the line the key is declared on, stable rule ids, and [baselines](docs/ci.md#adopting-it-on-a-project-that-already-ships) so a project with three hundred existing findings can switch the check on today.

## Installation

```bash
brew install asutekku/tap/xclocsmith
```

A universal binary, so no Swift toolchain is involved — which matters most on a CI runner, where installing one costs more than the check does. macOS 13+; `.xcstrings` itself needs Xcode 15 or newer.

Or take the same tarball by hand from [the latest release](https://github.com/asutekku/xclocsmith/releases/latest), or build it:

```bash
git clone https://github.com/asutekku/xclocsmith
cd xclocsmith
swift build -c release
cp .build/release/xclocsmith .build/release/xclocsmith-mcp /usr/local/bin/
```

Building needs Swift 5.9 — Xcode 15 or newer. Or run it from a checkout without installing: `swift run -c release xclocsmith check`.

## Getting started

```bash
cd path/to/your/app
xclocsmith init      # writes .xclocsmith.json describing your project
xclocsmith check     # translation coverage and catalog health
xclocsmith scan      # strings in your code that no catalog knows about

Examples/translate.sh ja de    # and then have a model fill in what is missing
```

`init` is optional — without a config the project is discovered from its layout. Write one when you want to name your targets, pin the language list, or teach the scanner about your own view types ([configuration reference](docs/configuration.md)).

Both `check` and `scan` exit **1** when they find something, so they gate CI directly. Neither writes a file unless you ask it to.

## Translating with a model

A model can translate a string catalog. What it cannot do is tell you whether it succeeded — a dropped `%@` or a Russian plural answered with one string is fluent, plausible output, and it compiles, passes review and ships. So the loop here is built around the step after the translation:

```
xclocsmith check --out   →  a template of exactly what is missing,
                            in the shape this language needs
        ↓
     a model fills it in
        ↓
xclocsmith add           →  merged into the catalog, plurals intact,
                            nothing else in the file touched
        ↓
xclocsmith check         →  exit 0, or the findings go back to the model
```

Every step speaks JSON and every step is exit-coded, so nothing in the loop needs prose parsing. [`Examples/translate.sh`](Examples/translate.sh) is that loop in 133 lines of shell: it re-prompts the model with the linter's findings when a language fails, and a language still failing after the second attempt fails the run and is named. Or drive it yourself:

```bash
xclocsmith check --lang ru --out work.json   # every missing Russian string
cat work.json | your-model | xclocsmith add -
xclocsmith check --lang ru                   # exit 0 only if it is actually right
```

The template, what the verify step catches, and the agent-side pieces — the MCP server and the Claude Code hook — are in [docs/translating.md](docs/translating.md) and [docs/agents.md](docs/agents.md).

## In CI

Copy this in whole. It annotates the pull request diff and files everything else as code-scanning alerts, on the line each key is declared on.

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

Failures are SARIF `error` and advisories `warning`, matching the exit code. GitHub only renders ten annotations of each level per step, so on a catalog with a backlog either lean on the SARIF upload, which has no such cap, or take a [baseline](docs/ci.md#adopting-it-on-a-project-that-already-ships) and let it fail only on what you add next. Both output formats, the annotation caps and baselines are in [docs/ci.md](docs/ci.md).

## Results on real projects

Nine open-source apps, `init && check && scan` with no hand-written config — 8,077 keys, 70 locales, 6,373 Swift files. Among the findings, all shipping today:

- Mastodon's Albanian translates `"Option %ld"` as `"%ld nga %ld"`, which reads a second argument the call never supplies.
- Mastodon's Kabyle dropped the `%1$@` numbering from `"%1$@, attachment %2$d of %3$d"`, so its values bind in written order.
- IceCubesApp changed a key's English to `"%lld posts"`; its Belarusian still reads `"%lld people talking"`, state `translated`.
- Whisky renders one of its two "Remove" buttons as German `"Löschen"` — delete — and the other as `"Entfernen"`.
- DuckDuckGo declares `NSLocalNetworkUsageDescription` in its Info.plist and localizes it nowhere, so that permission prompt is English for every non-English user.
- GoMap's GPX widget ships eleven fewer languages than the app beside it, so those users get a translated app and an English widget.

`check` tops out at 3.3s and `scan` at 2.9s, both on DuckDuckGo's 19 catalogs and 3,196 Swift files; Mastodon's 53 locales take 1.8s, and every other run in the table finishes in under a second. The full table, the analysis and the numbers per project are in [docs/results.md](docs/results.md); [`Scripts/corpus.sh`](Scripts/corpus.sh) reproduces them at the commits they were measured against.

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

**Exit codes:** `0` clean, `1` findings, `2` usage or I/O error. Every command that reports findings takes `--json`, and `<command> --help` lists exactly the flags it accepts — an unknown flag is an error, never a silent no-op. The full contract automation can rely on is in [docs/agents.md](docs/agents.md#the-cli-contract).

## Documentation

- [Translating with a model](docs/translating.md) — the loop, the template format, `translate.sh`, and what the verify step catches.
- [Checking catalogs](docs/checking.md) — failing rules, advisories, argument order, and `diff`.
- [Scanning your source](docs/scanning.md) — what `scan` recognizes, bypasses, and unreferenced keys.
- [The project around the catalogs](docs/project-checks.md) — Info.plist strings and per-bundle language gaps.
- [Editing catalogs](docs/editing.md) — `add`, `set`, `prune`, write guards, and `.xcloc` / `.xliff` import.
- [Configuration](docs/configuration.md) — `.xclocsmith.json` and in-source directives.
- [Continuous integration](docs/ci.md) — GitHub annotations, SARIF, and baselines.
- [Agents and automation](docs/agents.md) — the CLI contract, hooks, and the MCP server.
- [Results on real projects](docs/results.md) — the corpus table and analysis.

## Out of scope

- **Producing `.xcloc` bundles** — `xcodebuild -exportLocalizations` builds your project to gather strings from storyboards, Info.plist and asset catalogs, which no linter should try to reproduce.
- **`.strings` / `.stringsdict` migration** — Xcode's migrator owns this. Such files are only ever read as reference text, never rewritten.
- **Compiling catalogs or generating symbols** — that is `xcstringstool`. This tool validates *against* the symbol rules; it never emits symbols.
- **Storyboard and XIB string extraction**, and **translation quality** — not a localization linter's job.

## Contributing

`swift test` runs everything — 296 tests. The suite is the specification for what counts as a user-visible string: `ClassifierTests` is a table of Swift snippets and the keys Xcode would extract from them, and `RecallTests` holds the idioms real projects use. A change to detection behaviour belongs there first.

## Licence

MIT. See [LICENSE](LICENSE).
