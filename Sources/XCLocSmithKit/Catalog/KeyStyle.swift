import Foundation

/// A key that is an English sentence, carrying translations that an edit to
/// that sentence would destroy.
///
/// Using the English as the key is a documented Xcode style and works fine for
/// `"Save"`. It stops working when the key is prose, because then the key *is*
/// the content: rewording the sentence renames the key, a rename is
/// indistinguishable from a delete plus an add, and every translation
/// underneath is orphaned rather than flagged. Nothing can recover the intent
/// afterwards — `diff` reports one key added and one removed, and exits 0.
///
/// The same edit under an identifier key changes a value, not a key, so `diff`
/// names the stranded languages and fails.
public struct SentenceKey: Equatable, Sendable {
    public let key: String
    /// Non-source translations that would be orphaned by rewording the key.
    public let translationsAtRisk: Int

    public init(key: String, translationsAtRisk: Int) {
        self.key = key
        self.translationsAtRisk = translationsAtRisk
    }
}

public enum KeyStyle {

    /// Prose long enough that somebody will eventually reword it.
    ///
    /// Five words is where the corpus splits cleanly. Below it are the labels
    /// nobody rewrites — "Save", "Delete %@", "Show in Finder" — and flagging
    /// those is noise on a style that is legitimate at that length. At or above
    /// it are the sentences: GoMap keys 96 of them, holding 1,930 translations
    /// between them, one of them in 31 languages.
    ///
    /// Whisky, NetNewsWire and Mastodon key by identifier throughout and report
    /// nothing here, which is the point of the threshold — a project that has
    /// already made this decision should hear silence.
    public static let minimumWords = 5

    static func isSentence(_ key: String) -> Bool {
        // Whitespace is what makes it prose rather than an identifier;
        // `session.activitySegments.explanation` is long and has none.
        guard key.contains(where: \.isWhitespace) else { return false }
        return key.split(whereSeparator: \.isWhitespace).count >= minimumWords
    }

    /// Sentence keys with something to lose, worst first.
    ///
    /// A key with no translations yet is not reported: there is nothing an edit
    /// would destroy, and telling somebody to rename a key that costs nothing
    /// to reword is advice with no consequence attached.
    public static func sentenceKeys(in catalog: Catalog) -> [SentenceKey] {
        catalog.keys.compactMap { key -> SentenceKey? in
            guard isSentence(key) else { return nil }
            guard catalog.extractionState(key) != .stale else { return nil }
            let translations = catalog.languages
                .filter { $0 != catalog.sourceLanguage }
                .filter { catalog.value(key, $0) != nil }
                .count
            guard translations > 0 else { return nil }
            return SentenceKey(key: key, translationsAtRisk: translations)
        }
        .sorted {
            $0.translationsAtRisk == $1.translationsAtRisk
                ? $0.key < $1.key
                : $0.translationsAtRisk > $1.translationsAtRisk
        }
    }
}
