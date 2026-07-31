# Checking catalogs

```bash
xclocsmith check
xclocsmith check --lang ja,de       # only these languages
xclocsmith check --strict           # advisories fail too
xclocsmith check --out work.json    # write a fill-in template for what is missing
```

Coverage is reported per language per catalog, with the outstanding keys named rather than counted (lists truncate at 50). The counting follows Xcode's own semantics: a `stringUnit` in state `new` is untranslated, `needs_review` is reported separately, a `stale` key is on its way out and does not nag translators, and a declared language with no entries yet shows 0% instead of passing silently.

What fails the run:

- **Format specifiers that disagree with the source** — the classic localization crash, which no build step checks. Positional reordering (`%2$@ の %1$@`) is fine; substitutions (`%#@count@`) and plural variations are expanded and checked through — a German `other` that dropped its `%lld` is the single likeliest place for this bug to hide.
- **A translation that threw away the argument positions the source gave it** — see [argument order](#argument-order), the one that does not crash.
- **Incomplete plurals against real CLDR categories.** One filled row is complete for Japanese and three short for Russian; categories that only apply to decimals or compact millions (Czech `many`, French `many`) are not demanded. A flat translation of a pluralized key counts as incomplete too.
- **Keys that differ only in case**, which break Xcode's symbol generation.
- **Hygiene defects that lose text**: a "-" or "N/A" standing in for a translation nobody wrote, invisible and bidi-control characters, broken Markdown, mismatched line-break counts.
- **Glossary violations**, if you declare terms — a glossary is a decision you wrote down, so breaking it fails rather than advises.

What is advisory: one source string translated more than one way — "Free" the price and "Free" the vacancy are one English string with two right answers, so record reviewed pairs in [`ignoreSimilar`](configuration.md) — plus near-duplicates compared on the *strings* rather than the keys, translations identical to the source, and the softer hygiene rules: punctuation compared by class (`。`, `؟` and Greek `;` satisfy their Latin equivalents), edge whitespace, doubled words (reduplicating languages like Vietnamese are exempt), and `...` where the typographic ellipsis belongs.

## Argument order

The bug in this family that does *not* crash, and so survives every review: two values printed in the wrong order.

```console
$ xclocsmith check --lang kab          # Mastodon for iOS, wrapped to fit here
  FAIL  translation hygiene (2):
    dropped-specifier-position (2) — argument positions the source gave and the translation dropped:
      - [kab] "Common.Controls.Status.Media.AccessibilityLabel": the source numbers its
        arguments (%1$@, %2$d, %3$d) and this translation does not, so its specifiers
        bind in written order — if the sentence puts them the other way round, the
        values are silently swapped
      - [kab] "Scene.Register.Input.BirthDate.ExplanationMessage": …
```

`"%1$@, attachment %2$d of %3$d"` is `"%@, attachment %d of %d"` in Kabyle, and the birth-date message the same. Nothing else in the toolchain says a word about either.

Two checks, at the two places the mistake can be made:

- **`unordered-specifiers`, against the source** — a source string with two or more bare `%@` cannot be reordered *at all*, so a language that puts the object before the subject has no legal way to translate it. Advisory, because the translations that exist are as right as they can be; the fix is to number the source, and it costs nothing.
- **`dropped-specifier-position`, against each translation** — the source numbered its arguments and the translation did not. Same specifiers, same types, same count, so the format check passes and Xcode compiles it, but the bare specifiers now bind in written order and any reordering the sentence performs swaps the values. **This one fails the run:** nobody types `%1$@` by accident, so discarding it reverses a decision somebody made deliberately.

A translator who *adds* positions to a source that lacked them has fixed the problem, not caused one, and is not reported. Neither is a translation that reorders through positions, which is what positions are for.

## Reviewing a change (`diff`)

```bash
xclocsmith diff HEAD                         # every catalog, against a commit
xclocsmith diff old.xcstrings new.xcstrings  # two files, no git involved
```

The finding this exists for is a **source string that changed while its translations did not**. Xcode marks translations `needs_review` when *it* notices the source move — but only for edits made in its own editor. A string changed by a merge, a script, an `add` or a hand edit leaves every translation underneath reading `translated` and saying the wrong thing. `git diff` shows the English line changing; it cannot tell you which of the nineteen translations below it were left behind. IceCubesApp's stranded Belarusian in the [results table](results.md) is exactly this, caught here at the commit that introduces it instead of years later. The report names the stranded languages and suggests `set --state needs_review`; added and removed keys are notes, and only stranded translations fail.

## Keys that are sentences

`sentence-key` is advisory and reports what an edit would cost: keys of five words or more that carry at least one translation. Using the English as the key is a documented style and fine for `"Save"` — it stops working when the key is prose, because then rewording it is a rename, and a rename orphans every translation silently. [`rename`](editing.md#renaming-a-key) migrates one to an identifier.

Across the nine sample projects that is GoMap with 94 such keys holding 1,842 translations, one of them in 31 languages, and Loop with 96 holding 1,248. Whisky, NetNewsWire and Mastodon key by identifier throughout and report none.
