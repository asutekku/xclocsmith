# Editing catalogs

```bash
xclocsmith add translations.json           # a payload, one catalog and language
xclocsmith set "Save" "保存" --lang ja
xclocsmith prune                           # report unreferenced keys
xclocsmith prune --apply
```

Files are written byte-for-byte in Xcode's own format, so an edit produces a one-line diff instead of reordering the whole catalog. `add` and `set` merge into the existing structure and refuse, rather than silently flatten, when a localization holds plural variations or substitutions:

```
FAIL  1 key(s) not written:
  holds substitutions (%#@name@ arguments); pass --flatten to overwrite:
    - Found %#@count@
```

Refusals carry their reason, because "not in the catalog" and "would destroy plural variations" call for different fixes. The other guards:

- Keys differing only by case are refused — Xcode cannot generate symbols for both — including two such keys inside a single payload.
- `set` will not create a key that is not already in the catalog without `--create`, so a typo cannot quietly add one. Writing a language the catalog has never seen requires `--add-language`, and the error suggests the code you probably meant.
- `prune` refuses to remove more than a quarter of a catalog without `--force`, and never writes anything if any catalog trips that guard.
- Duplicate keys, canonically-equivalent keys (NFC vs NFD) and malformed numbers are rejected on read rather than "repaired" by dropping one.

The `add` payload is the filled-in template from [`check --out`](translating.md). Beyond plain `"key": "value"` pairs it takes a per-key `state` and `comment`, and a `plural` object for variations. `"TODO"` values are left alone, so a template can be filled in over several passes; a bare `{"key": "value"}` object also works, with `--lang` and the catalog from the command line; `-` reads from stdin.

## Localization catalogs (`.xcloc`)

When a vendor or an agent returns an Xcode Localization Catalog, the risky moment is the import: `xcodebuild -importLocalizations` warns about untranslated files, but it does not compare format specifiers, so a `%@` where your code passes an integer goes straight into the app.

```bash
xclocsmith xcloc check ja.xcloc      # validate before importing — reads only
xclocsmith xcloc apply ja.xcloc --apply
```

`xcloc check` reports format specifiers in each `<target>` against its `<source>`, plural units missing the categories the target language requires, `contents.json` and the XLIFF disagreeing about the target language, machine-translated units (`state-qualifier="leveraged-mt"`, which Xcode's agent workflow writes), units whose key is in none of your catalogs, and catalog keys the bundle omits. A bare `.xliff` works too, since localizers often return one.

`xcloc apply` is `-importLocalizations` without a project or a build: it routes each `<file>` element to the catalog for its table, merges into the existing structure, and maps XLIFF states onto catalog states — machine translation is always imported as `needs_review`, whatever the XLIFF claims. It will not invent keys (an XLIFF translates a catalog, it does not extend one) and it will not guess at a variation it does not recognize; both are reported and skipped.
