import Foundation

/// `stringUnit.state` as Xcode writes it.
public enum TranslationState: String, CaseIterable, Sendable {
    case new
    case needsReview = "needs_review"
    case translated
    case stale

    /// Xcode shows `new` as work still to do, not as a translation.
    public var countsAsTranslated: Bool {
        switch self {
        case .translated, .needsReview: return true
        case .new, .stale: return false
        }
    }
}

/// `extractionState` as Xcode writes it. Absent means "managed by the build":
/// the compiler extracted it and `xcstringstool sync` maintains it.
public enum ExtractionState: String, Sendable {
    case manual
    case migrated
    case extractedWithValue = "extracted_with_value"
    case stale

    /// Only manually-managed strings get generated symbols, so only they can
    /// collide by case at build time.
    public var isSymbolEligible: Bool { self == .manual }
}

/// Where a single (key, language) pair stands.
public enum TranslationStatus: Equatable, Sendable {
    /// No entry for this language.
    case missing
    /// An entry exists but its value is empty.
    case empty
    /// A flat string, with the state Xcode recorded.
    case unit(TranslationState)
    /// Plural or device variations; `missing` lists required categories that
    /// are absent or empty.
    case variations(missingCategories: [String])

    public var isComplete: Bool {
        switch self {
        case .missing, .empty: return false
        case .unit(let state): return state.countsAsTranslated
        case .variations(let missing): return missing.isEmpty
        }
    }

    /// Present but not yet signed off — reported separately from missing work.
    public var needsReview: Bool {
        if case .unit(let state) = self { return state == .needsReview || state == .new }
        return false
    }
}

/// One localization's shape, used to refuse destructive writes.
public struct LocalizationShape: Equatable, Sendable {
    public let hasStringUnit: Bool
    public let hasVariations: Bool
    public let hasSubstitutions: Bool

    public var isPlainString: Bool { !hasVariations && !hasSubstitutions }

    /// Human description of what a flat overwrite would destroy.
    public var structureDescription: String? {
        switch (hasVariations, hasSubstitutions) {
        case (true, true): return "plural/device variations and substitutions"
        case (true, false): return "plural/device variations"
        case (false, true): return "substitutions (%#@name@ arguments)"
        case (false, false): return nil
        }
    }
}
