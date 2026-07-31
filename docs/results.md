# Results on real projects

Nine open-source apps, `init && check && scan` with no hand-written config — 8,077 keys, 70 locales, 6,373 Swift files.

| Project | Catalogs · keys · locales | Broken format strings | Missing plural forms | Translated two ways | Hygiene fails / checked | Project-level | Sentence keys · translations at risk | Duplicate strings | Unlocalized in code |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|
| [Whisky](https://github.com/Whisky-App/Whisky) | 1 · 152 · 21 | 0 | 0 | **5** | **3** / 50 | 1 | 0 | 10 | 0 |
| [Loop](https://github.com/MrKai77/Loop) | 1 · 404 · 13 | 0 | 0 | **3** | **100** / 230 | 1 | **96** · 1,248 | 9 (+3 case) | 0 |
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | 9 · 472 · 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 (+4 case) | 85 |
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | 1 · 733 · 18 | **2** | **89** | **62** | **12** / 175 | 1 | **26** · 220 | 95 | 47 |
| [Mastodon for iOS](https://github.com/mastodon/mastodon-ios) | 9 · 980 · 53 | **9** | **53** | 0 | **68** / 273 | 3 | 0 | 122 | 27 |
| [HSTracker](https://github.com/HearthSim/HSTracker) | 23 · 777 · 13 | 0 | 0 | **5** | **2** / 45 | 2 | **44** · 384 | 64 (+1 case) | 10 |
| [Nimble Commander](https://github.com/mikekazakov/nimble-commander) | 54 · 1322 · 1 | 0 | **1** | **5** | **1** / 66 | 0 | **130** · 130 | 332 (+2 case) | 0 |
| [GoMap](https://github.com/bryceco/GoMap) | 15 · 761 · 33 | **4** | **150** | **28** | **14** / 80 | 9 | **94** · 1,842 | 79 (+3 case) | 10 |
| [DuckDuckGo](https://github.com/duckduckgo/apple-browsers) | 19 · 2476 · 26 | **20** | **48** | **25** | **82** / 172 | 1 | **21** · 168 | 352 | 166 |

**Bold** ships as a user-visible bug.

### Reading the table

- **Hygiene fails / checked** — hygiene findings that fail the run, out of every hygiene check performed. Most of the rest is punctuation and whitespace, which is advisory.
- **Project-level** — findings about the files *around* the catalogs: Info.plist strings, development region, per-bundle language gaps.
- **Sentence keys · translations at risk** — keys of five words or more that carry translations, and how many translations they hold. There the key *is* the English, so rewording it renames the key and orphans every translation under it: `diff` reports one key added, one removed, and exits 0. GoMap's worst single key is translated into 31 languages. [`rename`](editing.md#renaming-a-key) migrates one to an identifier, carrying the translations with it. Whisky, NetNewsWire and Mastodon key by identifier throughout and report none.
- **Duplicate strings** — exact duplicate groups plus near-duplicate pairs, so it contains the "translated two ways" column rather than sitting beside it. `(+n case)` counts keys differing only in case. Nimble Commander's 332 is 260 near-duplicates and 72 exact groups.
- **Unlocalized in code** — Nimble Commander's `0` means nothing: it is Objective-C++ with three Swift files, and Objective-C sources are not scanned at all. That is the largest gap in this tool today. Its `check` results are fully meaningful.

### What it found

Mastodon's Albanian translates `"Option %ld"` as `"%ld nga %ld"`, which reads a second argument the call never supplies. GoMap's Arabic translator pasted the *description* of a string into two of its plural forms, and the count went with it. Whisky renders one of its two "Remove" buttons as German `"Löschen"` — delete — and the other as `"Entfernen"`.

The "translated two ways" column is the one nothing else finds. Two keys with the same English are invisible in Xcode when a project keys by identifier, and their translations drift apart. IceCubesApp has 62 such groups, including a key whose English was changed to `"%lld posts"` and whose Belarusian still reads `"%lld people talking"` — state `translated`, and detectable only beside its twin. Mastodon's 122 duplicates all agree, because its translation memory propagates them.

The failing half of the hygiene column is mostly one thing: a placeholder where a translation should be. Whisky ships `config.notAvailable` as the literal string "N/A" in Czech, French and Romanian; Loop's Arabic and Flemish write "-" for sixty strings nobody has reached yet. Both read as translated in Xcode.

The project-level column is the smallest and the hardest to get any other way. DuckDuckGo declares `NSLocalNetworkUsageDescription` in its Info.plist and localizes it nowhere, so that permission prompt is English for every non-English user. GoMap's GPX widget carries eleven fewer languages than the app beside it — iOS resolves a language per bundle, so those users get a translated app and an English widget, and each catalog looks complete on its own.

Whisky and Loop genuinely have no unlocalized strings, and the tool finds none across their 213 files.

### Timings

`check` tops out at 3.0s and `scan` at 2.6s, both on DuckDuckGo's 19 catalogs and 3,196 Swift files; Mastodon's 53 locales take 1.8s to check, and every other run in the table finishes in under a second. `check` is the slower of the two on a project that size — the hygiene pass is thirteen comparisons per key per language, and DuckDuckGo is 2,476 keys across 26 locales.

Reproduce it with [`Scripts/corpus.sh`](../Scripts/corpus.sh), which clones the nine at the commits these numbers were measured against and prints the table.
