import Foundation

public struct SimilarPair: Equatable, Sendable {
    public let a: String
    public let b: String
    public let percent: Int
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

    /// Near-duplicate keys, with the deliberate ones filtered out.
    public static func similar(
        keys: [String],
        threshold: Int,
        ignored: Set<String>
    ) -> [SimilarPair] {
        let usable = keys.filter { key in
            KeyHeuristics.isTranslatable(key)
                && key.count >= 6
                && !FormatSpecifierScanner.containsSpecifier(key)
        }
        var candidates: [(key: String, chars: [Character])] = usable.map { ($0, Array($0.lowercased())) }
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
                if a.chars == b.chars { continue }               // a case duplicate
                if ignored.contains(canonicalPair(a.key, b.key)) { continue }
                if differOnlyInDigits(a.key, b.key) { continue }
                if differByOneUnrelatedWord(a.key, b.key) { continue }
                let limit = Similarity.distanceLimit(
                    longest: max(a.chars.count, b.chars.count),
                    threshold: threshold
                )
                let percent = Similarity.percent(a.chars, b.chars, limit: limit)
                if percent >= threshold { pairs.append(SimilarPair(a: a.key, b: b.key, percent: percent)) }
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
