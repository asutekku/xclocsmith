# Continuous integration

String Catalogs are macOS-only, so this wants a macOS runner. The copy-paste workflow is in [the README](../README.md#in-ci); it installs the released universal binary, which keeps a Swift toolchain out of the job entirely:

```yaml
      - run: brew install asutekku/tap/xclocsmith
```

If the tool is vendored into the repository instead, build it in the job and call it by path:

```yaml
jobs:
  localization:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift build -c release --package-path Tools/xclocsmith
      - run: Tools/xclocsmith/.build/release/xclocsmith check --format github
      - run: Tools/xclocsmith/.build/release/xclocsmith scan --format github
```

`check`, `scan`, `diff` and `xcloc check` take `--format github`, which annotates the PR diff, and `--format sarif`, which GitHub code scanning ingests. Both point at the line the key is declared on rather than at the top of a four-thousand-line catalog.

## `--format github`

Workflow commands on stdout, one per finding. GitHub turns each into an inline comment on the diff:

```console
$ xclocsmith check --format github
::error file=App/Localizable.xcstrings,line=14,title=missing-translation::"Export Backup" has no ru translation.
::error file=App/Localizable.xcstrings,line=4,title=format-mismatch::[ru] "Delete %25@" has 0 format specifier(s), the source has 1 — "Delete %25@" → "Удалить"
```

`%25` is not a bug: a literal `%` has to be percent-encoded in a workflow command, and GitHub decodes it, so the annotation reads `"Delete %@"` on the pull request. Failures are `::error`, advisories `::warning`.

Worth knowing before you point this at a large catalog: GitHub renders **10 warning, 10 error and 10 notice annotations per step, and 50 per job** — [documented in `actions/toolkit`](https://github.com/actions/toolkit/blob/main/docs/problem-matchers.md). Findings past that are still in the log and still fail the run, but they are not annotated. On a project with a backlog, either take a [baseline](#adopting-it-on-a-project-that-already-ships) first, or use SARIF, which has no such cap.

## `--format sarif`

The whole document, from the same two findings — this is the entire output, not an excerpt:

```json
{
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "runs": [
    {
      "results": [
        {
          "level": "error",
          "locations": [
            {
              "physicalLocation": {
                "artifactLocation": {
                  "uri": "App/Localizable.xcstrings",
                  "uriBaseId": "%SRCROOT%"
                },
                "region": {
                  "startLine": 14
                }
              }
            }
          ],
          "message": {
            "text": "\"Export Backup\" has no ru translation."
          },
          "ruleId": "missing-translation"
        },
        {
          "level": "error",
          "locations": [
            {
              "physicalLocation": {
                "artifactLocation": {
                  "uri": "App/Localizable.xcstrings",
                  "uriBaseId": "%SRCROOT%"
                },
                "region": {
                  "startLine": 4
                }
              }
            }
          ],
          "message": {
            "text": "[ru] \"Delete %@\" has 0 format specifier(s), the source has 1 — \"Delete %@\" → \"Удалить\""
          },
          "ruleId": "format-mismatch"
        }
      ],
      "tool": {
        "driver": {
          "informationUri": "https://github.com/asutekku/xclocsmith",
          "name": "xclocsmith",
          "rules": [
            {
              "defaultConfiguration": {
                "level": "error"
              },
              "fullDescription": {
                "text": "A key has no translation in a language being checked."
              },
              "help": {
                "text": "A key has no translation in a language being checked."
              },
              "id": "missing-translation",
              "name": "missing-translation",
              "shortDescription": {
                "text": "A key has no translation in a language being checked."
              }
            },
            {
              "defaultConfiguration": {
                "level": "error"
              },
              "fullDescription": {
                "text": "A translation's format specifiers disagree with the source string."
              },
              "help": {
                "text": "A translation's format specifiers disagree with the source string."
              },
              "id": "format-mismatch",
              "name": "format-mismatch",
              "shortDescription": {
                "text": "A translation's format specifiers disagree with the source string."
              }
            }
          ],
          "version": "0.1.1"
        }
      }
    }
  ],
  "version": "2.1.0"
}
```

Points worth noticing, because they are what makes the difference between a file GitHub accepts and one it rejects:

- **`tool.driver.rules` carries only the rules this run actually used**, each with its `defaultConfiguration.level`. Code scanning shows that description beside the alert, so a reviewer who has never heard of `format-mismatch` still knows what it means.
- **Paths are repository-relative under `%SRCROOT%`.** A finding in a file outside the project root is emitted as an absolute `file://` URI with no `uriBaseId`, since there is nothing for GitHub to resolve it against.
- **Failures are `error` and advisories are `warning`**, matching the exit code, and `--strict` makes advisories fail the run too.
- **Rule ids are stable** — `missing-translation`, `format-mismatch`, `divergent-translation`, `string-not-in-catalog`, `placeholder-translation` and so on — so a dismissal or a filter written against one keeps working. They are the same ids a [baseline](#adopting-it-on-a-project-that-already-ships) records.

Uploading it is the standard action:

```yaml
      - run: xclocsmith check --format sarif > localization.sarif
      - uses: github/codeql-action/upload-sarif@v3
        if: always()          # the step above exits 1 on findings; still upload
        with:
          sarif_file: localization.sarif
```

## Adopting it on a project that already ships

A mature catalog has hundreds of findings. There is no version of "fix these first" that ends with the check switched on, so the check never gets switched on, and the next defect arrives unnoticed.

```bash
xclocsmith check --update-baseline                        # accept what is there today
xclocsmith check --baseline .xclocsmith-baseline.json     # fails only on what is new
```

Whisky goes from 68 failing and 513 advisory findings to clean; adding one key with a dropped `%@` puts it back to failing. The file is sorted, readable JSON rather than hashes — deleting a line un-suppresses a finding, and a pull request diff says which string stopped being accepted. There are no globs and no wildcards: every entry names one finding, so nothing is silenced by accident.

Entries that match nothing are reported too. A baseline nobody prunes stops being a ratchet and becomes a drawer.
