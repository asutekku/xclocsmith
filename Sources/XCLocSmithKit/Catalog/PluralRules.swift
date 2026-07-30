import Foundation

/// Which CLDR cardinal plural categories a language actually needs.
///
/// Xcode's plural editor shows exactly the rows a language requires, and a
/// missing row falls back at runtime — so "one filled row means translated" is
/// wrong for every language more complex than Japanese.
///
/// Categories are split in two:
///
/// - `required` — reachable by ordinary integer counts (0…100). A missing or
///   empty row here is a real defect: Russian without `few` mistranslates 2–4.
/// - `optional` — categories CLDR defines only for decimals or very large
///   compact numbers (French `many` starts at 1,000,000; Czech `many` is
///   decimals only). Absent rows here are not worth failing a build over.
///
/// Data follows CLDR cardinal plural rules. Languages not listed fall back to
/// `other` alone, which is the safe assumption: it never invents a false
/// requirement.
public enum PluralRules {
    public static let allCategories = ["zero", "one", "two", "few", "many", "other"]

    public struct Categories: Equatable, Sendable {
        public let required: [String]
        public let optional: [String]

        init(_ required: [String], optional: [String] = []) {
            self.required = required
            self.optional = optional
        }
    }

    /// Normalises `pt-BR`, `zh-Hans`, `es_419` to a base language code.
    public static func baseLanguage(_ code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        return String(normalized.split(separator: "-").first ?? "")
    }

    public static func categories(for language: String) -> Categories {
        table[baseLanguage(language)] ?? Categories(["other"])
    }

    /// True when we have real CLDR data rather than the `other`-only fallback.
    public static func isKnown(_ language: String) -> Bool {
        table[baseLanguage(language)] != nil
    }

    private static let onlyOther = Categories(["other"])
    private static let oneOther = Categories(["one", "other"])

    private static let table: [String: Categories] = {
        var table: [String: Categories] = [:]

        // No plural distinction at all.
        for code in [
            "ja", "zh", "ko", "th", "vi", "id", "ms", "my", "km", "lo", "yue", "bo",
            "dz", "ig", "ii", "jv", "kde", "kea", "lkt", "nqo", "sah", "ses", "sg",
            "to", "wo", "yo", "za", "su",
        ] { table[code] = onlyOther }

        // one / other — most European and Indic languages.
        for code in [
            "en", "de", "nl", "sv", "da", "nb", "nn", "no", "fi", "et", "it", "es",
            "ca", "gl", "eu", "el", "hu", "tr", "bg", "af", "sq", "hy", "ka", "fa",
            "kk", "ky", "uz", "az", "ne", "mr", "pa", "gu", "bn", "hi", "ta", "te",
            "ml", "kn", "si", "ur", "sw", "is", "mk", "lb", "fo", "eo", "fil", "tl",
            "am", "as", "or", "zu", "st", "sn", "xh", "nso", "tk", "mn", "ha", "yi",
            "sd", "ps", "kok", "brx", "ceb", "chr", "ee", "gsw", "haw", "ku", "mas",
            "nd", "nr", "ny", "om", "os", "pap", "rm", "rof", "rwk", "saq", "seh",
            "so", "ss", "ssy", "syr", "teo", "tig", "tn", "ts", "ve", "vo", "vun",
            "wae", "xog", "kab", "tzm",
        ] { table[code] = oneOther }

        // French and Portuguese: CLDR `many` only applies to compact millions.
        table["fr"] = Categories(["one", "other"], optional: ["many"])
        table["pt"] = Categories(["one", "other"], optional: ["many"])

        // East Slavic and Polish: 1, 2–4, 5–20 all differ for ordinary counts.
        for code in ["ru", "uk", "be", "pl"] {
            table[code] = Categories(["one", "few", "many", "other"])
        }
        // West Slavic: `many` is the decimal form only.
        for code in ["cs", "sk"] {
            table[code] = Categories(["one", "few", "other"], optional: ["many"])
        }
        // South Slavic (Bosnian/Croatian/Serbian).
        for code in ["hr", "sr", "bs", "sh"] {
            table[code] = Categories(["one", "few", "other"])
        }

        table["lt"] = Categories(["one", "few", "other"], optional: ["many"])
        table["lv"] = Categories(["zero", "one", "other"])
        table["ro"] = Categories(["one", "few", "other"])
        table["mo"] = Categories(["one", "few", "other"])
        table["sl"] = Categories(["one", "two", "few", "other"])
        table["he"] = Categories(["one", "two", "other"], optional: ["many"])
        table["iw"] = Categories(["one", "two", "other"], optional: ["many"])
        table["ar"] = Categories(["zero", "one", "two", "few", "many", "other"])
        table["cy"] = Categories(["zero", "one", "two", "few", "many", "other"])
        table["kw"] = Categories(["zero", "one", "two", "few", "many", "other"])
        table["ga"] = Categories(["one", "two", "few", "many", "other"])
        table["gd"] = Categories(["one", "two", "few", "other"])
        table["br"] = Categories(["one", "two", "few", "many", "other"])
        table["mt"] = Categories(["one", "two", "few", "many", "other"])
        table["gv"] = Categories(["one", "two", "few", "many", "other"])
        table["dsb"] = Categories(["one", "two", "few", "other"])
        table["hsb"] = Categories(["one", "two", "few", "other"])
        table["shi"] = Categories(["one", "few", "other"])
        table["lag"] = Categories(["zero", "one", "other"])
        table["ksh"] = Categories(["zero", "one", "other"])
        table["naq"] = Categories(["one", "two", "other"])
        for code in ["se", "sma", "smj", "smn", "sms"] {
            table[code] = Categories(["one", "two", "other"])
        }

        return table
    }()
}
