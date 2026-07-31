# Scanning your source

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
in the [config](configuration.md)); a wrapper function is found by *reading its
body* — if its first parameter reaches a localization API, it localizes, while
a function merely named `localize` does not qualify. Likewise your own views:
if `StatRow` renders its `label` through `LocalizedStringKey`, then
`StatRow(label: "Best Drop")` is a key, and the same parameter name on a type
that does not localize it stays quiet.

Partial arguments count — `Text(flag ? "Yes" : "No")` is two keys,
`Text("Hello \(name)")` is matched against `"Hello %@"` — and tables resolve at
the call site, so `Text("Failed", tableName: "Errors")` is checked against
`Errors.xcstrings` even when the key exists in some other table.

**Bypasses** are advisories: `Text(verbatim:)`, string concatenation, UIKit
`label.text =` and `setTitle(_:)` — all of which display text no catalog will
translate. Test code is not scanned, and keys still living in a `.strings` file
are counted as localized, not reported.

**Keys nothing references** feed [`prune`](editing.md). Deleting is
irreversible, so the check is deliberately hard to satisfy: a key survives if
it is mentioned anywhere in the Swift text, a XIB, plist, storyboard,
`.strings` or JSON file. `InfoPlist.xcstrings`, `AppShortcuts.xcstrings` and
Interface Builder keys like `3aJ-8X-AqP.title` are exempt entirely.
