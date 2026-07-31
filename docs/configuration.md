# Configuration

`.xclocsmith.json`, found by walking up from the working directory. Everything is optional; `xclocsmith init` writes one.

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
  "ignoreSimilar": [["Max Temperature", "Min Temperature"]],
  "glossary": {
    "Onsen": { "ja": "温泉", "de": "Onsen" },
    "Furolog": { "*": "Furolog" }
  }
}
```

| Key | Meaning |
|---|---|
| `targets` | What compiles into what. `sources` are files that ship in this target; its `catalogs` must contain their strings. |
| `referenceSources` | Scanned only to decide whether a key is still used. Put shared packages here when you are not sure which targets compile them. |
| `inferred` | Written by `init` when a target was guessed from the directory layout. While present, a key found in another target's catalog for the same table counts. Delete it once the sources really are that target's. |
| `languages` | Languages to check, even if the catalog has no entries for one yet. |
| `excludePaths` | Glob patterns against repo-relative paths. |
| `exclude`, `excludeAlso` | Directory names never walked into. `exclude` replaces the built-in list (`.build`, `Pods`, `Carthage`, …); `excludeAlso` adds to it, which is almost always the one you want. |
| `referenceExtensions` | File types searched when deciding whether a key is still referenced — beyond Swift. Defaults to plists, `.strings`, storyboards, XIBs, Objective-C, JSON and YAML. |
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
