# Translating with a model

A model can translate a string catalog. What it cannot do is tell you whether it succeeded — dropping a `%@`, answering a Russian plural with one string and inventing a second argument are all fluent, plausible output, and all three compile, pass review and ship. So the loop here is built around the step after the translation:

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

Every step speaks JSON (`--json` on everything but `init`) and every step is exit-coded, so nothing in the loop needs prose parsing and nothing needs a human to look at it.

## Just ask an agent

With `xclocsmith` on `PATH`, there is no setup and no script. In Claude Code, Cursor, or any agent that can run a command:

> Use xclocsmith to translate every missing Japanese string in this project.

The agent runs the loop itself:

```console
$ xclocsmith check --lang ja --out work.json
  FAIL  missing ja translations (12): …
Wrote work-App-Localizable-ja.json
Wrote work-App-Errors-ja.json
```

One payload per catalog and language, each naming its own catalog and language, so the agent applies them with `xclocsmith add work-App-Localizable-ja.json` and no other arguments. Then `xclocsmith check --lang ja` again — and if it exits 1, the findings name the key and the language, and go straight back into the next attempt.

Nothing above had to be explained to the model. That is deliberate:

- **`--help` lists exactly the flags a command takes**, and an unknown flag is an error rather than a silent no-op, so a guessed invocation fails loudly instead of appearing to work.
- **The template carries the shape**, so the model never has to know that Russian takes four plural forms — the categories arrive as keys waiting to be filled.
- **`add` reports every key** as written, skipped or refused. A slot still holding `"TODO"` is skipped and stays missing; a key that would have flattened a plural is refused. A model that only read the exit code would call both a success.
- **The verify step is a different program from the one that translated**, which is the entire point. It has no stake in the answer being right.

Two optional pieces, when the agent is already working in the project:

- **The [MCP server](agents.md#mcp-server)** exposes the same loop as separate, individually-permissioned tools — `translation_template`, `add_translations`, `check_catalogs` — so a host can grant the reading half freely and confirm the writes.
- **The [`PostToolUse` hook](agents.md#editor-and-commit-hooks)** works the other end: when an agent writes a Swift file it hears immediately that the string it just typed reaches no catalog, and when it writes a catalog, that it broke a format specifier. Exit 2 hands the message back, so it fixes what it wrote in the same turn.

Worth putting in `CLAUDE.md` or `AGENTS.md`, so it happens without being asked:

```markdown
Localization is checked by `xclocsmith`. Never hand-edit an `.xcstrings` file.

- After adding user-visible strings, run `xclocsmith scan`.
- To translate: `xclocsmith check --lang <code> --out work.json`, replace every
  `"TODO"` in each file it writes, apply each with `xclocsmith add <file>`, then
  run `xclocsmith check --lang <code>` again and fix what it reports.
```

## In a script, or in CI

[`Examples/translate.sh`](../Examples/translate.sh) is the same loop unattended, in 133 lines of shell:

```console
$ Examples/translate.sh ja
── ja ─────────────────────────────────────────────
translating work.json
App/Localizable.xcstrings [ja]: 1 translated
ja: the linter rejected the translation, asking again
    FAIL  format specifiers disagree with the source string (1):
      - [ja] "You have %lld messages" has 0 format specifier(s), the source has 1
          "You have %lld messages"  →  "メッセージ"
App/Localizable.xcstrings [ja]: 1 updated
ja: clean on the second attempt
```

The model dropped the count out of a string it translated perfectly well otherwise. Nothing in Xcode would have said so; the app crashes or silently loses the number, in Japanese only, months later. Here the finding goes back to the model with the payload it wrote, it fixes that one string, and the run re-verifies before it reports success. **A language still failing after the second attempt fails the run and is named**; that attempt is left in the working tree to look at, rather than reported as done.

It takes any number of languages, and `TRANSLATOR` is any command that reads a template on stdin and writes a filled one on stdout — a model, a script, a translation API. The default is Claude Code in headless mode:

```bash
Examples/translate.sh ja de fr
STATE=needs_review Examples/translate.sh ja      # queue it for a human reviewer
TRANSLATOR="./deepl.sh" Examples/translate.sh ja
```

Or drive it yourself; there is nothing in the script but these three commands:

```bash
xclocsmith check --lang ru --out work.json   # every missing Russian string
cat work.json | your-model | xclocsmith add -
xclocsmith check --lang ru                   # exit 0 only if it is actually right
```

`add` reads `-` for stdin. `check --out` writes one template per catalog and language — with a single catalog it uses the name you gave, and with several it derives one per catalog, so the fan-out is a `for` loop rather than a merge.

## What the model is asked for

The template asks for the shape the *target language* needs, because nobody should have to know that Russian takes four plural forms and Japanese one:

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

`source` and `comment` are read-only context and `add` ignores them. On a project that keys by identifier they are the difference between translating `notifications.label.favorite` and translating something nobody can see. Keys that are already their own English string stay in the short `"key": "TODO"` form.

## What the verify step catches

Everything under [Checking catalogs](checking.md) runs against what the model wrote, but these are the ones machine translation actually trips on:

- **A dropped or invented format specifier.** The crash, and the one that survives review because the sentence reads fine.
- **A plural answered with one string**, or with categories this language does not use. `add` refuses to flatten a plural into a flat string at all unless you pass `--flatten`.
- **A placeholder left behind** — `"-"`, `"N/A"`, `"TBD"`. A model that ran out of context mid-file leaves these, and they read as `translated` in Xcode. A slot still holding the literal `"TODO"` never reaches the catalog at all: `add` reports it skipped, so the key stays missing and stays in the next template.
- **The English handed back untouched**, reported as identical-to-source.
- **The same source string translated two ways**, which is what happens when a model does one catalog on Monday and its neighbour on Friday.
- **Your glossary**, if you declared one — product names and terms of art are exactly what a model paraphrases, and a glossary violation fails rather than advises.

Two more entry points into the same machinery: [`scan --template`](scanning.md) writes the same kind of template for user-visible strings that are in no catalog *yet*, so a model can localize a feature that was written in English; and [`xcloc check`](editing.md#localization-catalogs-xcloc) applies all of it to an `.xcloc` or `.xliff` bundle before you import it, whether a vendor or an agent produced it.
