import Foundation

/// Mechanical defects in a translation, found by comparing it against its
/// source string.
///
/// None of these need to know what the words mean, which is why a tool can find
/// them and a reviewer who does not read the language cannot. They are the
/// checks every translation-management system runs and no Xcode build step
/// does: a dropped colon runs a label into the value beside it, a trimmed
/// trailing space closes up two words that were meant to be spaced, a
/// zero-width space breaks a string comparison somewhere far away.
///
/// The design constraint throughout is **not firing on correct translations**.
/// Every rule below is narrower than the obvious version of itself, because
/// punctuation, spacing and word repetition are all things languages
/// legitimately disagree about, and a check that cries wolf on Japanese full
/// stops gets the whole group switched off.
public struct HygieneFinding: Equatable, Sendable {
    public enum Rule: String, Sendable, CaseIterable {
        /// The source ends in punctuation the translation does not.
        case endPunctuation = "end-punctuation"
        /// Leading or trailing whitespace that does not match the source.
        case edgeWhitespace = "edge-whitespace"
        /// Two spaces in a row where the source has one.
        case doubleSpace = "double-space"
        /// The translation has a different number of line breaks.
        case newlineCount = "newline-count"
        /// A character that is invisible and does nothing but break comparisons.
        case invisibleCharacter = "invisible-character"
        /// A bidirectional override, or an embedding that is never closed.
        case bidiControl = "bidi-control"
        /// U+FFFD — the file has already survived an encoding accident.
        case replacementCharacter = "replacement-character"
        /// French requires a non-breaking space before `!`, `?`, `;` and `:`.
        case punctuationSpacing = "punctuation-spacing"
        /// The same word twice in a row.
        case doubledWord = "doubled-word"
        /// Markdown the source has and the translation broke.
        case markdown = "markdown"
        /// `^[…](inflect: true)` dropped, so grammar agreement stops applying.
        case inflectionDropped = "inflection-dropped"
        /// Every plural category filled with the same text.
        case samePlurals = "same-plurals"
        /// A dash or a "TODO" standing in for a translation nobody wrote.
        case placeholderTranslation = "placeholder-translation"
        /// Source-side: `...` where the typographic ellipsis belongs.
        case ellipsisStyle = "ellipsis-style"
        /// Source-side: two or more specifiers a translator cannot reorder.
        case unorderedSpecifiers = "unordered-specifiers"

        var isFailure: Bool {
            switch self {
            // Text has been lost, mangled, or is about to render as markup.
            case .invisibleCharacter, .bidiControl, .replacementCharacter,
                 .markdown, .inflectionDropped, .newlineCount,
                 .placeholderTranslation:
                return true
            // Reads badly, and there are hundreds of them on any catalog with
            // history behind it.
            // `samePlurals` is advisory because an abbreviated form is allowed
            // not to inflect: Mastodon's Arabic "مُنذُ %ldي" ("%ldd ago") is the
            // same in all six categories on purpose, and that is 34 of its 34.
            case .endPunctuation, .edgeWhitespace, .doubleSpace, .samePlurals,
                 .punctuationSpacing, .doubledWord, .ellipsisStyle,
                 .unorderedSpecifiers:
                return false
            }
        }

        public var summary: String {
            switch self {
            case .endPunctuation: return "punctuation that disagrees with the source"
            case .edgeWhitespace: return "leading or trailing space that disagrees with the source"
            case .doubleSpace: return "two spaces in a row"
            case .newlineCount: return "a different number of line breaks from the source"
            case .invisibleCharacter: return "an invisible character that breaks string comparison"
            case .bidiControl: return "a bidirectional override or an unclosed embedding"
            case .replacementCharacter: return "U+FFFD, so text was lost converting encodings"
            case .punctuationSpacing: return "French punctuation without its non-breaking space"
            case .doubledWord: return "the same word twice in a row"
            case .markdown: return "Markdown the translation broke"
            case .inflectionDropped: return "grammar agreement markup the translation dropped"
            case .samePlurals: return "every plural form filled with the same text"
            case .placeholderTranslation: return "a placeholder where a translation should be"
            case .ellipsisStyle: return "\"...\" where the typographic ellipsis belongs"
            case .unorderedSpecifiers: return "specifiers a translator cannot reorder"
            }
        }
    }

    public let rule: Rule
    public let key: String
    /// The language the defect is in. The source language for the two
    /// source-side rules, which are about the string you wrote.
    public let language: String
    public let detail: String

    /// Whether this fails a run or only reports.
    ///
    /// The split is by what a user sees, not by how sure the check is. A
    /// translation carrying U+FFFD has already lost characters; a translation
    /// that dropped a trailing colon reads badly. Both are worth reporting and
    /// only one is worth stopping a build for — and a mature catalog has
    /// hundreds of the second kind, so failing on them means the check gets
    /// turned off on exactly the projects that need it.
    public var isFailure: Bool { rule.isFailure }

    public init(rule: Rule, key: String, language: String, detail: String) {
        self.rule = rule
        self.key = key
        self.language = language
        self.detail = detail
    }
}

public enum Hygiene {

    /// Every hygiene defect in one key's translation.
    public static func check(
        key: String,
        source: String,
        translation: String,
        language: String
    ) -> [HygieneFinding] {
        guard !source.isEmpty, !translation.isEmpty else { return [] }
        var findings: [HygieneFinding] = []

        func report(_ rule: HygieneFinding.Rule, _ detail: String) {
            findings.append(HygieneFinding(rule: rule, key: key, language: language, detail: detail))
        }

        // A translation that is a bare "-" is not a translation, and every
        // other rule then reports a symptom of it: Loop's Arabic and Flemish
        // both write "-" for strings nobody has got to yet, and that alone
        // accounted for most of its punctuation findings.
        if let detail = placeholder(source: source, translation: translation) {
            report(.placeholderTranslation, detail)
            return findings
        }
        if let detail = endPunctuation(source: source, translation: translation, language: language) {
            report(.endPunctuation, detail)
        }
        if let detail = edgeWhitespace(source: source, translation: translation) {
            report(.edgeWhitespace, detail)
        }
        if translation.contains("  "), !source.contains("  ") {
            report(.doubleSpace, "two spaces in a row, where the source has one")
        }
        let sourceBreaks = lineBreakCount(source)
        let translationBreaks = lineBreakCount(translation)
        if sourceBreaks != translationBreaks {
            report(
                .newlineCount,
                "\(translationBreaks) line break(s), the source has \(sourceBreaks)"
            )
        }
        for detail in invisibleCharacters(source: source, translation: translation) {
            report(.invisibleCharacter, detail)
        }
        for detail in bidiProblems(translation) {
            report(.bidiControl, detail)
        }
        if translation.unicodeScalars.contains("\u{FFFD}"), !source.unicodeScalars.contains("\u{FFFD}") {
            report(.replacementCharacter, "contains U+FFFD, so text was lost converting encodings")
        }
        if let detail = frenchPunctuationSpacing(translation, language: language) {
            report(.punctuationSpacing, detail)
        }
        // Only when the *source* does not do it too. GoMap's interface-builder
        // keys really are "Detail Detail" and "Mapbox Mapbox", and Loop has a
        // key called "Fourth Fourth"; every translation of those repeats the
        // word because the string does.
        if doubledWord(source, language: "en") == nil,
           let detail = doubledWord(translation, language: language) {
            report(.doubledWord, detail)
        }
        for detail in markdownProblems(source: source, translation: translation) {
            report(.markdown, detail)
        }
        if source.contains("(inflect: true)"), !translation.contains("(inflect: true)") {
            report(
                .inflectionDropped,
                "the source uses ^[…](inflect: true); without it the translation gets no grammar agreement"
            )
        }
        return findings
    }

    /// Defects in the source string itself — the ones that make a *translator's*
    /// job impossible rather than recording that they did it badly.
    public static func checkSource(
        key: String,
        source: String,
        language: String
    ) -> [HygieneFinding] {
        guard !source.isEmpty else { return [] }
        var findings: [HygieneFinding] = []

        // A literal "..." is three full stops: it line-breaks between them, it
        // reads as three periods to a screen reader, and Apple's own interface
        // guidelines call for the single character.
        if source.contains("...") {
            findings.append(HygieneFinding(
                rule: .ellipsisStyle,
                key: key,
                language: language,
                detail: "uses \"...\" where the typographic ellipsis \"…\" belongs"
            ))
        }

        // Two bare specifiers cannot be reordered, and German, Japanese and
        // Turkish all routinely need to. `%1$@ %2$@` costs nothing to write and
        // gives the translator the freedom the sentence needs.
        let specifiers = FormatSpecifierScanner.specifiers(in: source)
        let unordered = specifiers.filter { $0.position == nil }
        if unordered.count > 1 {
            findings.append(HygieneFinding(
                rule: .unorderedSpecifiers,
                key: key,
                language: language,
                detail: "\(unordered.count) specifiers with no argument position, "
                    + "so no translation can reorder them — write %1$@, %2$@"
            ))
        }
        return findings
    }

    /// Every plural category saying the same thing.
    ///
    /// The categories exist to be different. Filling them all with one string
    /// satisfies the structure and produces exactly the text a flat translation
    /// would have — which is what someone does when a tool demands four rows and
    /// nobody told them why.
    ///
    /// A language legitimately reaches this for `zero`/`one`/`two` in some
    /// phrasings, so it takes *all* required categories being identical, and at
    /// least three of them.
    public static func samePlurals(
        key: String,
        catalog: Catalog,
        language: String
    ) -> HygieneFinding? {
        let required = PluralRules.categories(for: language).required
        guard required.count >= 3 else { return nil }
        let entries = catalog.comparableEntries(key, language)
            .filter { $0.path.hasPrefix("plural.") }
        guard entries.count >= 3 else { return nil }
        let values = Set(entries.map(\.value))
        guard values.count == 1, let only = values.first, !only.isEmpty else { return nil }

        return HygieneFinding(
            rule: .samePlurals,
            key: key,
            language: language,
            detail: "all \(entries.count) plural forms are \"\(only)\" — the categories exist to differ"
        )
    }

    /// A stand-in rather than a translation.
    ///
    /// Deliberately narrow: the source has to be real words and the
    /// translation has to have no letters at all, or be one of the handful of
    /// markers people type when they mean "come back to this". A translation
    /// of "—" for a source of "—" is a real translation of a dash.
    private static let placeholderMarkers: Set<String> = ["todo", "tbd", "n/a", "na", "xxx", "???", "fixme"]

    static func placeholder(source: String, translation: String) -> String? {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard source.contains(where: \.isLetter) else { return nil }

        if placeholderMarkers.contains(trimmed.lowercased()) {
            return "the translation is \"\(trimmed)\", which is a note to self, not a translation"
        }
        // An explicit set rather than "contains no letters": a family emoji is
        // one grapheme cluster with no letters in it, and is a translation.
        let placeholderCharacters: Set<Character> = ["-", "–", "—", "_", ".", "·", "?", "*", "•"]
        guard trimmed.count <= 3, trimmed.allSatisfy({ placeholderCharacters.contains($0) }) else {
            return nil
        }
        return "the translation is \"\(trimmed)\" — a placeholder, not a translation"
    }

    // MARK: - End punctuation

    /// Punctuation that means the same thing in a different script.
    ///
    /// Comparing characters rather than classes reports every CJK translation
    /// of every sentence, because Japanese ends one with `。` and not `.`. Each
    /// row below is one mark and the forms of it that other writing systems use.
    private static let punctuationClasses: [Set<Character>] = [
        [".", "。", "．", "۔", "።", "।", "॥", "‧"],
        ["?", "？", "؟", "՞", "፧"],
        ["!", "！", "՜", "᥄", "‼"],
        [":", "：", "፡"],
        [";", "；", "؛", "፤"],
        ["…", "⋯", "︙"],
    ]

    /// Languages where `;` is not a semicolon. Greek writes its question mark
    /// that way, so a Greek question ending `;` is correct and comparing it
    /// against an English `?` as a different class is not.
    private static let greekQuestionMark: Set<String> = ["el"]

    static func endPunctuation(source: String, translation: String, language: String) -> String? {
        guard let sourceMark = trailingPunctuation(source) else { return nil }
        let translationMark = trailingPunctuation(translation)

        // Greek `;` is a question mark, so it satisfies a source `?`.
        if greekQuestionMark.contains(PluralRules.baseLanguage(language)) {
            if sourceMark == "?", translationMark == ";" { return nil }
        }
        guard let sourceClass = punctuationClasses.first(where: { $0.contains(sourceMark) }) else {
            return nil
        }
        if let translationMark, sourceClass.contains(translationMark) { return nil }

        // An ellipsis written as three full stops still ends in a full stop, so
        // check the whole tail before calling it a mismatch.
        if sourceClass.contains("…"), translation.hasSuffix("...") { return nil }
        if sourceClass.contains("."), source.hasSuffix("..."), translation.hasSuffix("…") { return nil }

        guard let translationMark else {
            return "the source ends with \"\(sourceMark)\" and the translation ends with no punctuation"
        }
        return "the source ends with \"\(sourceMark)\" and the translation with \"\(translationMark)\""
    }

    /// The last character, if it is punctuation. Trailing whitespace and
    /// closing brackets or quotes are stepped over: `Really? "` still ends in a
    /// question mark for this purpose.
    private static func trailingPunctuation(_ value: String) -> Character? {
        let skippable: Set<Character> = [" ", "\u{00A0}", "\"", "'", "”", "’", "»", ")", "]", "}", "」", "』", "\n"]
        var index = value.endIndex
        while index > value.startIndex {
            index = value.index(before: index)
            let character = value[index]
            if skippable.contains(character) { continue }
            return character.isPunctuation || character.isSymbol ? character : nil
        }
        return nil
    }

    // MARK: - Whitespace

    /// Leading and trailing space that disagrees with the source.
    ///
    /// A trailing space is nearly always load-bearing — it separates this string
    /// from whatever is drawn next to it — so a translator tidying it away
    /// closes up two words. It is one of the most common findings in every
    /// translation QA system for exactly that reason.
    static func edgeWhitespace(source: String, translation: String) -> String? {
        func isSpace(_ character: Character) -> Bool {
            character.isWhitespace && !character.isNewline
        }
        let sourceLeading = source.prefix(while: isSpace).count
        let translationLeading = translation.prefix(while: isSpace).count
        if sourceLeading != translationLeading {
            return translationLeading == 0
                ? "the source starts with a space and the translation does not"
                : "the translation starts with \(translationLeading) space(s), the source with \(sourceLeading)"
        }
        let sourceTrailing = source.reversed().prefix(while: isSpace).count
        let translationTrailing = translation.reversed().prefix(while: isSpace).count
        if sourceTrailing != translationTrailing {
            return translationTrailing == 0
                ? "the source ends with a space and the translation does not"
                : "the translation ends with \(translationTrailing) space(s), the source with \(sourceTrailing)"
        }
        return nil
    }

    private static func lineBreakCount(_ value: String) -> Int {
        value.filter { $0 == "\n" }.count
    }

    // MARK: - Unicode

    /// Characters that are invisible and carry no meaning here.
    ///
    /// Deliberately short. Zero-width joiners and non-joiners are *load-bearing*
    /// in Persian, Arabic and the Indic scripts, and inside emoji sequences —
    /// flagging those would report correct text in the languages least able to
    /// argue back. The three below have no such use in UI strings.
    private static let uselessInvisibles: [(Unicode.Scalar, String)] = [
        ("\u{200B}", "U+200B zero-width space"),
        ("\u{FEFF}", "U+FEFF byte-order mark"),
        ("\u{2060}", "U+2060 word joiner"),
    ]

    static func invisibleCharacters(source: String, translation: String) -> [String] {
        var problems: [String] = []
        for (scalar, name) in uselessInvisibles {
            let inTranslation = translation.unicodeScalars.filter { $0 == scalar }.count
            guard inTranslation > 0 else { continue }
            // Present in the source too means somebody put it there on purpose.
            guard !source.unicodeScalars.contains(scalar) else { continue }
            problems.append("contains \(name), which breaks string comparison and displays as nothing")
        }
        return problems
    }

    /// Bidirectional controls that are wrong rather than merely present.
    ///
    /// An RTL translator adding a left-to-right *mark* around a phone number is
    /// doing the job properly, so marks are left alone. Overrides and unclosed
    /// embeddings are different: they change the direction of everything that
    /// follows, including text this string does not own.
    static func bidiProblems(_ value: String) -> [String] {
        var problems: [String] = []
        let scalars = Array(value.unicodeScalars)

        if scalars.contains("\u{202D}") || scalars.contains("\u{202E}") {
            problems.append(
                "contains a bidirectional override (U+202D/U+202E), which reverses how "
                    + "the rest of the line is read"
            )
        }
        // U+202A/B embeddings close with U+202C; U+2066–8 isolates with U+2069.
        // Overrides are reported above; counting them here as well bills one
        // character twice.
        let embeddings = scalars.filter { $0 == "\u{202A}" || $0 == "\u{202B}" }.count
        let pops = scalars.filter { $0 == "\u{202C}" }.count
        if embeddings > pops {
            problems.append("has \(embeddings - pops) unclosed bidirectional embedding(s) (missing U+202C)")
        }
        let isolates = scalars.filter { ("\u{2066}"..."\u{2068}").contains($0) }.count
        let isolatePops = scalars.filter { $0 == "\u{2069}" }.count
        if isolates > isolatePops {
            problems.append("has \(isolates - isolatePops) unclosed directional isolate(s) (missing U+2069)")
        }
        return problems
    }

    // MARK: - French spacing

    /// French sets a non-breaking space before `!`, `?`, `;` and `:`.
    ///
    /// With an ordinary space the mark can wrap to the next line on its own;
    /// with none at all the text is simply wrong to a French reader. Canadian
    /// French keeps the rule for `:` only, so it is left out entirely rather
    /// than half-checked.
    private static let doublePunctuation: Set<Character> = ["!", "?", ";", ":"]

    static func frenchPunctuationSpacing(_ translation: String, language: String) -> String? {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        guard PluralRules.baseLanguage(language) == "fr", !normalized.hasPrefix("fr-ca") else {
            return nil
        }
        let characters = Array(translation)
        for (index, character) in characters.enumerated() where doublePunctuation.contains(character) {
            guard index > 0 else { continue }
            // Prose punctuation ends a clause: it is followed by a space or by
            // nothing. A colon inside `https://` or `12:30` is neither, and
            // French sets no space before either of them.
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            if let after, !after.isWhitespace { continue }
            let before = characters[index - 1]
            if before == " " {
                return "\"\(character)\" is preceded by an ordinary space; French takes a "
                    + "non-breaking space (U+202F or U+00A0) so the mark cannot wrap alone"
            }
            if before == "\u{00A0}" || before == "\u{202F}" { continue }
            if before.isWhitespace { continue }
            return "\"\(character)\" has no space before it; French takes a non-breaking space"
        }
        return nil
    }

    // MARK: - Doubled words

    /// Languages that repeat a word as a grammatical device, where "buku buku"
    /// is a plural rather than a slip.
    private static let reduplicating: Set<String> = [
        "id", "ms", "tl", "fil", "jv", "su", "mi", "haw", "sw",
        // Vietnamese reduplicates as ordinary vocabulary: "luôn luôn" is
        // "always", and GoMap's Vietnamese uses it in a permission string.
        "vi", "th", "km", "lo", "zu", "xh", "af",
    ]

    static func doubledWord(_ value: String, language: String) -> String? {
        guard !reduplicating.contains(PluralRules.baseLanguage(language)) else { return nil }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 1 else { return nil }

        for (first, second) in zip(words, words.dropFirst()) {
            guard first.count >= 3 else { continue }
            guard first.allSatisfy({ $0.isLetter }) else { continue }
            guard first.lowercased() == second.lowercased() else { continue }
            // "had had", "that that" — English really does do this.
            guard !legitimateRepeats.contains(first.lowercased()) else { continue }
            return "\"\(first) \(second)\" — the same word twice"
        }
        return nil
    }

    /// Words a language really does write twice in a row. Mostly reflexive
    /// pronouns, which sit directly before their verb: French "vous vous
    /// souvenez", Spanish "se se", German "sie sie".
    private static let legitimateRepeats: Set<String> = [
        "had", "that", "very", "sehr", "très", "muy", "molto",
        "vous", "nous", "que", "sie", "wir", "les", "des", "los", "las",
    ]

    // MARK: - Markdown

    /// `LocalizedStringKey` renders a Markdown subset, so broken markup in a
    /// translation ships as literal asterisks and brackets.
    ///
    /// Only checked when the *source* uses Markdown. A translation containing an
    /// asterisk for some other reason is not this tool's business.
    static func markdownProblems(source: String, translation: String) -> [String] {
        var problems: [String] = []

        let sourceLinks = linkCount(source)
        if sourceLinks > 0 {
            let translationLinks = linkCount(translation)
            if translationLinks != sourceLinks {
                problems.append(
                    "\(translationLinks) Markdown link(s), the source has \(sourceLinks)"
                )
            }
        }

        for marker in ["**", "*", "_", "`"] {
            let sourceCount = occurrences(of: marker, in: source, excludingLonger: marker == "*")
            guard sourceCount > 0, sourceCount.isMultiple(of: 2) else { continue }
            let translationCount = occurrences(of: marker, in: translation, excludingLonger: marker == "*")
            guard !translationCount.isMultiple(of: 2) else { continue }
            problems.append(
                "\(translationCount) \"\(marker)\" marker(s) — an odd number leaves the markup unclosed"
            )
        }
        return problems
    }

    /// Markdown links, not counting Apple's grammar-agreement markup, which
    /// happens to contain the same `](` and is checked by its own rule.
    private static func linkCount(_ value: String) -> Int {
        let withoutInflection = value.replacingOccurrences(
            of: "](inflect:",
            with: "]("
        ) == value
            ? value
            : value.replacingOccurrences(of: "](inflect:", with: "\u{1}")
        return occurrences(of: "](", in: withoutInflection, excludingLonger: false)
    }

    /// Counts a marker, optionally not counting it where it is part of a longer
    /// run — a `*` inside `**` is bold, not emphasis.
    private static func occurrences(of marker: String, in value: String, excludingLonger: Bool) -> Int {
        let characters = Array(value)
        let pattern = Array(marker)
        var count = 0
        var index = 0
        while index + pattern.count <= characters.count {
            guard Array(characters[index..<(index + pattern.count)]) == pattern else {
                index += 1
                continue
            }
            if excludingLonger {
                let before = index > 0 ? characters[index - 1] : nil
                let after = index + pattern.count < characters.count
                    ? characters[index + pattern.count]
                    : nil
                if before == pattern[0] || after == pattern[0] {
                    index += 1
                    continue
                }
            }
            count += 1
            index += pattern.count
        }
        return count
    }
}
