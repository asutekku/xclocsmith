# The project around the catalogs

Checks that need more than a catalog to answer, which is why nothing else runs them. The two big ones both ship as a user in some language reading English.

**Info.plist strings that reach no catalog.** DuckDuckGo declares `NSLocalNetworkUsageDescription` in its Info.plist and in none of its `InfoPlist.xcstrings`, so that permission prompt is English for every non-English user. Both places a modern project can declare these are read — the `Info.plist` file and the `INFOPLIST_KEY_…` build settings Xcode generates it from — and only permission descriptions and `CFBundleDisplayName` count, because `CFBundleName` is `$(PRODUCT_NAME)` almost everywhere.

**Catalogs shipping fewer languages than their neighbours.** iOS resolves a language per *bundle*, not per app: an `Errors.xcstrings` with twelve languages beside a `Localizable.xcstrings` with twenty means eight locales get a translated interface and English error messages. Each catalog looks complete on its own, and Xcode never puts them side by side. GoMap's GPX widget carries eleven fewer languages than the app around it.

One smaller check in the same family: a bundle whose declared development region is not the catalog's source language is reported (`development-region-mismatch`).
