# Results on real projects

Nine open-source apps, `init && check && scan` with no hand-written config —
8,077 keys, 70 locales, 6,373 Swift files.

| Project | Catalogs · keys · locales | Broken format strings | Missing plural forms | Translated two ways | Hygiene | Project | Duplicate strings ‡ | Unlocalized in code |
|---|---|---:|---:|---:|---:|---:|---|---:|
| [Whisky](https://github.com/Whisky-App/Whisky) | 1 · 152 · 21 | 0 | 0 | **5** | **3** / 50 | 1 | 10 | 0 |
| [Loop](https://github.com/MrKai77/Loop) | 1 · 404 · 13 | 0 | 0 | **3** | **100** / 230 | 1 | 9 (+3 case) | 0 |
| [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | 9 · 472 · 1 | 0 | 0 | 0 | 0 | 1 | 0 (+4 case) | 85 |
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | 1 · 733 · 18 | **2** | **89** | **62** | **12** / 175 | 1 | 95 | 47 |
| [Mastodon for iOS](https://github.com/mastodon/mastodon-ios) | 9 · 980 · 53 | **9** | **53** | 0 | **68** / 273 | 3 | 122 | 27 |
| [HSTracker](https://github.com/HearthSim/HSTracker) | 23 · 777 · 13 | 0 | 0 | **5** | **2** / 45 | 2 | 64 (+1 case) | 10 |
| [Nimble Commander](https://github.com/mikekazakov/nimble-commander) | 54 · 1322 · 1 | 0 | **1** | **5** | **1** / 66 | 0 | 332 (+2 case) | 0 † |
| [GoMap](https://github.com/bryceco/GoMap) | 15 · 761 · 33 | **4** | **150** | **28** | **14** / 80 | 9 | 79 (+3 case) | 10 |
| [DuckDuckGo](https://github.com/duckduckgo/apple-browsers) | 19 · 2476 · 26 | **20** | **48** | **25** | **82** / 172 | 1 | 352 | 166 |

**Bold** ships as a user-visible bug; the hygiene column reads *failing / total*.
Mastodon's Albanian `"Option %ld"` is translated `"%ld nga %ld"`, which reads a
second argument the call never supplies. GoMap's Arabic translator pasted the
*description* of a string into two of its plural forms, and the count went with
it. Whisky renders one of its two "Remove" buttons as German `"Löschen"` —
delete — and the other as `"Entfernen"`.

The "translated two ways" column is the one nothing else finds. Two keys with
the same English are invisible in Xcode when a project keys by identifier, and
their translations drift apart. IceCubesApp has 62 such groups, including a key
whose English was changed to `"%lld posts"` and whose Belarusian still reads
`"%lld people talking"` — state `translated`, and detectable only beside its
twin. Mastodon's 122 duplicates all agree, because its translation memory
propagates them.

The failing half of the hygiene column is mostly one thing: a placeholder where
a translation should be. Whisky ships `config.notAvailable` as the literal
string "N/A" in Czech, French and Romanian; Loop's Arabic and Flemish write "-"
for sixty strings nobody has reached yet. Both read as translated in Xcode. The
rest of the column is punctuation, whitespace and Unicode — advisory, because it
is loud on any catalog with history behind it.

The project column is the smallest and the hardest to get any other way, because
it is about the files *around* the catalogs. DuckDuckGo declares
`NSLocalNetworkUsageDescription` in its Info.plist and localizes it nowhere, so
that permission prompt is English for every non-English user. GoMap's GPX widget
carries eleven fewer languages than the app beside it — iOS resolves a language
per bundle, so those users get a translated app and an English widget, and each
catalog looks complete on its own.

Whisky and Loop genuinely have no unlocalized strings, and the tool finds none
across their 213 files.

`check` tops out at 3.3s and `scan` at 2.9s, both on DuckDuckGo's 19 catalogs
and 3,196 Swift files; Mastodon's 53 locales take 1.8s to check, and every
other run in the table finishes in under a second. `check` is the slower of the
two on a project that size — the hygiene pass is thirteen comparisons per key
per language, and DuckDuckGo is 2,476 keys across 26 locales.

Reproduce it with [`Scripts/corpus.sh`](../Scripts/corpus.sh), which clones the
nine at the commits these numbers were measured against and prints the table.

‡ Exact duplicate groups *plus* near-duplicate pairs, so it includes the
"translated two ways" column rather than sitting beside it. For Nimble Commander
it is 260 near-duplicates and 72 exact groups.

† Nimble Commander is Objective-C++: 54 catalogs, three Swift files. `check` is
fully meaningful there, `scan` is not — Objective-C sources are not scanned at
all, which is the largest gap in this tool today.
