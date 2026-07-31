# xclocsmith documentation

The [top-level README](../README.md) is the landing page; the full reference lives here, one topic per file.

- [Translating with a model](translating.md) — asking an agent to do it, the `check --out` → model → `add` → `check` loop, the template format, and what the verify step catches.
- [Checking catalogs](checking.md) — what `check` fails on and what it only advises, the argument-order checks, and `diff` for translations stranded by a source-string change.
- [Scanning your source](scanning.md) — how `scan` finds user-visible strings, what it recognizes, bypasses, and unreferenced keys.
- [The project around the catalogs](project-checks.md) — unlocalized Info.plist strings and catalogs shipping fewer languages than their neighbours.
- [Editing catalogs](editing.md) — `add`, `set`, `prune`, the write guards, and validating or importing an `.xcloc` / `.xliff`.
- [Configuration](configuration.md) — `.xclocsmith.json`, every key, and the in-source ignore directives.
- [Continuous integration](ci.md) — `--format github` and `--format sarif`, annotation caps, and baselines for projects that already ship.
- [Agents and automation](agents.md) — the CLI contract, editor and commit hooks, and the MCP server.
- [Results on real projects](results.md) — the nine-app corpus, the full table, and what it found.
