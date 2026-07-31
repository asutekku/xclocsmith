# Agents and automation

The tool is built to be driven by a machine — a script, a CI job, or a model
working in the project. The batch shape of that is the
[translation loop](translating.md); this page covers the pieces around it: the
guarantees the CLI makes to automation, the editor and commit hooks, and the
MCP server.

## The CLI contract

**Exit codes:** `0` clean, `1` findings, `2` usage or I/O error. An unknown
`--lang` fails the run instead of checking nothing and reporting clean.
`lookup` exits 1 when nothing matched; `prune` exits 2 when it refuses to act,
because a refusal needs a decision, not a fix.

Rules the CLI follows so automation cannot go wrong quietly: a flag a command
does not take is an error, never a silent no-op — `<command> --help` lists
exactly what is accepted — and so is a value flag whose next argument is
another flag, because `scan --out --json` is a forgotten filename, not a
request for a file called `--json`. Every command that reports findings takes
`--json` (everything but `init`), rendered from the same report object as the
text output so the two cannot drift; `failures` in the JSON equals the findings
enumerated in it, so fixing everything in the payload reaches exit 0. `--` ends
flag parsing, so a key can be any string: `xclocsmith set -- "--odd key" "値"`.

## Editor and commit hooks

`scan --files` reports on the files you name while still reading the whole
project — whether `L("Take a bath")` is a localization call depends on a
`func L` declared in some other file, so a linter that reads one file in
isolation both misses real findings and invents fake ones. Fast enough to run
on every save, on every project in the [results table](results.md).

Two ready hooks are in [`Examples/hooks/`](../Examples/hooks):

- **`pre-commit`** — checks the staged Swift and catalogs, nothing else.
  `ln -s ../../Examples/hooks/pre-commit .git/hooks/pre-commit`.
- **`claude-code-hook.py`** — a Claude Code `PostToolUse` hook. When an agent
  writes a Swift file it hears about strings that reach no catalog; when it
  writes a catalog, about broken format specifiers, case collisions and a
  string it just gave a second translation. Exit 2 hands the message back to
  the model, so it fixes what it wrote instead of hearing about it at review
  time.

Neither hook asks about translation coverage: a string added in this edit has
no Japanese yet and is not supposed to. That is what `check` across the project
is for, at a moment when somebody means to translate — see
[Translating with a model](translating.md) for the other half, where an agent
fills that Japanese in and has to prove it.

## MCP server

`xclocsmith-mcp` speaks the Model Context Protocol over stdio. It is how an
agent runs the [translation loop](translating.md) itself rather than being
handed a template: find what is missing, write it, check its own work. The
reason to prefer it over shelling out is permission granularity — the reading
tools and the writing tools are separate, annotated tools, so a host can grant
one set and confirm the other.

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
`set_translation` accept `dryRun` — and results carry the same report the
CLI's `--json` emits. The server has no dependencies either; `swift build`
produces it alongside the CLI.
