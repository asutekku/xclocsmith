import Foundation

/// Keys whose source strings are character-for-character the same.
///
/// On a project that keys by identifier this is invisible in Xcode: nothing in
/// the editor puts `settings.button.apply` next to `profile.button.apply`, so
/// the same English string gets entered twice and then translated twice, by
/// different people, months apart.
public struct DuplicateSource: Equatable, Sendable {
    /// The shared source-language string.
    public let text: String
    public let keys: [String]
    /// Languages that do not render `text` the same way under every key.
    public let divergences: [Divergence]

    public init(text: String, keys: [String], divergences: [Divergence]) {
        self.text = text
        self.keys = keys
        self.divergences = divergences
    }
}

/// One language rendering a shared source string more than one way.
public struct Divergence: Equatable, Sendable {
    public let language: String
    public let renderings: [Rendering]

    public init(language: String, renderings: [Rendering]) {
        self.language = language
        self.renderings = renderings
    }
}

public struct Rendering: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A term the project has decided must translate one particular way.
public struct GlossaryViolation: Equatable, Sendable {
    public let key: String
    public let language: String
    public let term: String
    public let expected: String
    public let source: String
    public let translation: String
}

/// Terms whose translation is fixed by the project rather than left to whoever
/// happens to be translating.
///
/// Product names, feature names and units are the usual contents: the point is
/// less that a translator will get "Onsen" wrong once and more that five
/// translators over three years will each get it differently.
public struct Glossary: Equatable, Sendable {
    /// term → language → required rendering. The language `*` applies to every
    /// language, which is how a name that must survive translation untouched is
    /// written.
    public var terms: [String: [String: String]]

    public init(terms: [String: [String: String]] = [:]) {
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// The rendering `language` must use for `term`, if any.
    public func rendering(of term: String, in language: String) -> String? {
        guard let renderings = terms[term] else { return nil }
        return renderings[language]
            ?? renderings[PluralRules.baseLanguage(language)]
            ?? renderings["*"]
    }
}

public enum Consistency {
    /// Keys grouped by identical source text, and the languages where those
    /// keys disagree.
    ///
    /// There is deliberately no minimum length here. Near-duplicate detection
    /// needs one — edit distance between two four-character strings means
    /// nothing — but an exact match is exact at any length, and the strings most
    /// likely to be entered twice are the short ones: "Apply", "Done", "Retry".
    public static func duplicateSources(
        in catalog: Catalog,
        languages: [String],
        ignored: Set<String> = []
    ) -> [DuplicateSource] {
        var byText: [String: [(key: String, text: String)]] = [:]
        for key in catalog.keys {
            guard catalog.shouldTranslate(key) else { continue }
            guard catalog.extractionState(key) != .stale else { continue }
            // In a literal-keyed catalog the key *is* the source string and no
            // source-language unit is written; `check`'s coverage already reads
            // it that way. Without the fallback, a literal "Remove" and an
            // identifier key whose English is "Remove" can never meet.
            let text = catalog.displayText(key, catalog.sourceLanguage) ?? key
            let folded = foldedSourceText(text)
            guard folded.count > 1, KeyHeuristics.isTranslatable(folded) else { continue }
            byText[folded, default: []].append((key, text))
        }

        var results: [DuplicateSource] = []
        for (_, members) in byText where members.count > 1 {
            let sorted = members.sorted { $0.key < $1.key }
            let keys = sorted.map(\.key)
            // The folded form found the group; the text as entered names it.
            let text = sorted[0].text
            // A pair the project has already looked at and kept stays quiet.
            // Requiring *every* pair to be listed means adding one member to a
            // group brings the group back, which is the right way round.
            if allPairsIgnored(keys, ignored) { continue }

            var divergences: [Divergence] = []
            for language in languages where language != catalog.sourceLanguage {
                var renderings: [Rendering] = []
                for key in keys {
                    guard let value = catalog.displayText(key, language), !value.isEmpty else { continue }
                    renderings.append(Rendering(key: key, value: value))
                }
                // One key translated and the others not is missing work, which
                // is already reported as missing work.
                guard renderings.count > 1 else { continue }
                guard Set(renderings.map(\.value)).count > 1 else { continue }
                divergences.append(Divergence(language: language, renderings: renderings))
            }
            results.append(DuplicateSource(text: text, keys: keys, divergences: divergences))
        }

        // Groups that actually disagree come first: they name a string a user
        // sees two ways today, where the rest are only housekeeping.
        return results.sorted { left, right in
            left.divergences.count == right.divergences.count
                ? left.text < right.text
                : left.divergences.count > right.divergences.count
        }
    }

    /// Source texts that differ only typographically are one string entered
    /// twice. "Apply " with a trailing space, "Don\u{2019}t" with a curly
    /// apostrophe against "Don't" with a straight one, a no-break space for a
    /// plain one — each is the same English to everyone except an exact match,
    /// and the short ones ("Apply") are below the near-duplicate pass's length
    /// floor, so nothing else would ever surface them. Grouping compares this
    /// folded form; reports show the text as it was entered.
    ///
    /// Canonically-equivalent sequences (NFC vs NFD) need no handling here:
    /// Swift string equality already treats them as equal.
    static func foldedSourceText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.map { character in
            switch character {
            case "\u{00A0}", "\u{202F}": return " " as Character     // no-break spaces
            case "\u{2018}", "\u{2019}": return "'" as Character     // curly apostrophes
            default: return character
            }
        })
    }

    private static func allPairsIgnored(_ keys: [String], _ ignored: Set<String>) -> Bool {
        guard !ignored.isEmpty else { return false }
        for (index, a) in keys.enumerated() {
            for b in keys[(index + 1)...] where !ignored.contains(SimilarKeys.canonicalPair(a, b)) {
                return false
            }
        }
        return true
    }

    /// Translations that drop or replace a term the glossary fixes.
    public static func glossaryViolations(
        in catalog: Catalog,
        glossary: Glossary,
        keys: [String],
        languages: [String]
    ) -> [GlossaryViolation] {
        guard !glossary.isEmpty else { return [] }
        var violations: [GlossaryViolation] = []

        for key in keys {
            // Literal-keyed catalogs carry no source-language unit: the key is
            // the source string. Skipping them left the glossary silently dead
            // on every catalog keyed by its English.
            let source = catalog.displayText(key, catalog.sourceLanguage) ?? key
            let applicable = glossary.terms.keys.filter { contains(term: $0, in: source) }
            guard !applicable.isEmpty else { continue }

            for language in languages where language != catalog.sourceLanguage {
                guard let translation = catalog.displayText(key, language), !translation.isEmpty else { continue }
                for term in applicable.sorted() {
                    guard let expected = glossary.rendering(of: term, in: language) else { continue }
                    // Case-sensitive: a glossary is a decision someone wrote
                    // down, and "furolog" is not the product's name.
                    guard !translation.contains(expected) else { continue }
                    violations.append(GlossaryViolation(
                        key: key,
                        language: language,
                        term: term,
                        expected: expected,
                        source: source,
                        translation: translation
                    ))
                }
            }
        }
        return violations.sorted {
            ($0.language, $0.term, $0.key) < ($1.language, $1.term, $1.key)
        }
    }

    /// Case-insensitive substring search that will not match inside a word, so
    /// the term "Loop" does not fire on "Looping" or "Bloop".
    static func contains(term: String, in text: String) -> Bool {
        let needle = Array(term.lowercased())
        let haystack = Array(text.lowercased())
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }

        for start in 0...(haystack.count - needle.count) {
            guard Array(haystack[start..<(start + needle.count)]) == needle else { continue }
            if start > 0, isWordCharacter(haystack[start - 1]) { continue }
            let end = start + needle.count
            if end < haystack.count, isWordCharacter(haystack[end]) { continue }
            return true
        }
        return false
    }

    /// Whether a character can hold a word together, for the purpose of
    /// deciding that a match landed inside one.
    ///
    /// `isLetter` alone is the obvious implementation and it is wrong. Every
    /// character of 新しい温泉セッション is a letter, so a boundary rule built on
    /// it rejects `温泉` — the term is always adjacent to another letter, because
    /// Japanese does not separate words. The same rule would then also refuse to
    /// find "Furolog" in Japanese and Korean sentences that attach particles
    /// straight onto a Latin name: `Furologを開く`, `Furolog을 시작`.
    ///
    /// So only scripts that actually put spaces between words get a boundary.
    private static func isWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        return !character.unicodeScalars.contains(where: isUnsegmented)
    }

    private static func isUnsegmented(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0E7F,     // Thai
             0x0E80...0x0EFF,     // Lao
             0x0F00...0x0FFF,     // Tibetan
             0x1000...0x109F,     // Myanmar
             0x1100...0x11FF,     // Hangul jamo (NFD-decomposed syllables)
             0x1780...0x17FF,     // Khmer
             0x3040...0x30FF,     // hiragana and katakana
             0x3130...0x318F,     // Hangul compatibility jamo
             0x31F0...0x31FF,     // katakana phonetic extensions
             0x3400...0x4DBF,     // CJK unified ideographs extension A
             0x4E00...0x9FFF,     // CJK unified ideographs
             0xA960...0xA97F,     // Hangul jamo extended A
             0xA9E0...0xA9FF,     // Myanmar extended B
             0xAA60...0xAA7F,     // Myanmar extended A
             0xAC00...0xD7FF,     // Hangul syllables
             0xF900...0xFAFF,     // CJK compatibility ideographs
             0xFF66...0xFF9F,     // halfwidth katakana
             0x20000...0x3FFFF:   // CJK ideograph extensions B onward
            return true
        default:
            return false
        }
    }
}
