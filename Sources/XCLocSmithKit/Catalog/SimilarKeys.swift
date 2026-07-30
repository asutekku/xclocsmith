import Foundation

public struct SimilarPair: Equatable, Sendable {
    public let a: String
    public let b: String
    public let percent: Int
    /// The source-language text that was actually compared, when the keys are
    /// identifiers and so do not show it.
    public let aText: String?
    public let bText: String?

    public init(a: String, b: String, percent: Int, aText: String? = nil, bText: String? = nil) {
        self.a = a
        self.b = b
        self.percent = percent
        self.aText = aText
        self.bText = bText
    }
}

public struct CaseDuplicate: Equatable, Sendable {
    public let keys: [String]
    /// True when at least two of them generate symbols, which is when Xcode's
    /// build actually fails.
    public let breaksSymbolGeneration: Bool
}

public enum SimilarKeys {
    public static func canonicalPair(_ a: String, _ b: String) -> String {
        a < b ? "\(a)\u{1}\(b)" : "\(b)\u{1}\(a)"
    }

    /// Keys differing only in case.
    ///
    /// This only breaks the build for strings Xcode generates symbols for —
    /// manually-managed ones. `xcstringstool generate-symbols` accepts
    /// case-variant *extracted* keys, so those are reported as advisory.
    public static func caseDuplicates(in catalog: Catalog) -> [CaseDuplicate] {
        var byLowercase: [String: [String]] = [:]
        for key in catalog.keys { byLowercase[key.lowercased(), default: []].append(key) }
        return byLowercase.values
            .filter { $0.count > 1 }
            .map { group in
                let symbolEligible = group.filter { catalog.extractionState($0)?.isSymbolEligible ?? false }
                return CaseDuplicate(keys: group.sorted(), breaksSymbolGeneration: symbolEligible.count > 1)
            }
            .sorted { $0.keys[0] < $1.keys[0] }
    }

    /// Near-duplicate strings, with the deliberate ones filtered out.
    ///
    /// The comparison is on the *source-language text*, never on the key. Two
    /// keys spelled `Scene.Collections.remove` and `Scene.Collections.removeMe`
    /// share a namespace, not a meaning — on a project that keys by identifier,
    /// comparing keys reports every sibling in every namespace and buries the
    /// real signal, which is one English string entered twice.
    public static func similar(
        entries: [(key: String, text: String)],
        threshold: Int,
        ignored: Set<String>
    ) -> [SimilarPair] {
        let usable = entries.filter { entry in
            KeyHeuristics.isTranslatable(entry.text)
                && entry.text.count >= 6
                && !FormatSpecifierScanner.containsSpecifier(entry.text)
        }
        var candidates: [(key: String, text: String, chars: [Character], folded: String)] =
            usable.map { ($0.key, $0.text, Array($0.text.lowercased()), Consistency.foldedSourceText($0.text)) }
        candidates.sort { left, right in
            left.chars.count == right.chars.count ? left.key < right.key : left.chars.count < right.chars.count
        }

        var pairs: [SimilarPair] = []
        guard candidates.count > 1 else { return pairs }

        for index in 0..<(candidates.count - 1) {
            let a = candidates[index]
            let longestComparable = (a.chars.count * 100) / threshold
            for other in (index + 1)..<candidates.count {
                let b = candidates[other]
                if b.chars.count > longestComparable { break }   // sorted by length
                // An exact match is `duplicateSources`' finding, and it reports
                // it better: one group of n keys rather than n² pairs, with the
                // languages that render them differently attached. Folded, so a
                // pair differing only by a trailing space or a curly apostrophe
                // moves over with the rest of the exact matches.
                if a.folded == b.folded { continue }
                // Skip only when `caseDuplicates` will report the pair anyway.
                // Two identifier keys whose English differs solely in case are
                // not case-duplicate *keys*, so nothing else would catch them.
                if a.chars == b.chars, a.key.lowercased() == b.key.lowercased() { continue }
                if ignored.contains(canonicalPair(a.key, b.key)) { continue }
                if differOnlyInDigits(a.text, b.text) { continue }
                if differByOneUnrelatedWord(a.text, b.text) { continue }
                let limit = Similarity.distanceLimit(
                    longest: max(a.chars.count, b.chars.count),
                    threshold: threshold
                )
                let percent = Similarity.percent(a.chars, b.chars, limit: limit)
                guard percent >= threshold else { continue }
                pairs.append(SimilarPair(
                    a: a.key,
                    b: b.key,
                    percent: percent,
                    aText: a.text == a.key ? nil : a.text,
                    bText: b.text == b.key ? nil : b.text
                ))
            }
        }
        pairs.sort { $0.percent == $1.percent ? $0.a < $1.a : $0.percent > $1.percent }
        return pairs
    }

    /// "Step 1" / "Step 12", "30 Days" / "90 Days".
    static func differOnlyInDigits(_ a: String, _ b: String) -> Bool {
        a.filter { !$0.isNumber } == b.filter { !$0.isNumber } && a != b
    }

    /// "Max Temperature" / "Min Temperature" — one word differs and the two
    /// words are unrelated, so the pair is a deliberate opposite.
    static func differByOneUnrelatedWord(_ a: String, _ b: String) -> Bool {
        let left = a.lowercased().split(separator: " ")
        let right = b.lowercased().split(separator: " ")
        guard left.count == right.count, left.count > 1 else { return false }

        var differing: [(String, String)] = []
        for (first, second) in zip(left, right) where first != second {
            differing.append((String(first), String(second)))
        }
        guard differing.count == 1 else { return false }
        return Similarity.percent(differing[0].0, differing[0].1) < 60
    }

    public static func caseVariants(of key: String, in keys: [String]) -> [String] {
        let lowered = key.lowercased()
        return keys.filter { $0 != key && $0.lowercased() == lowered }.sorted()
    }
}
