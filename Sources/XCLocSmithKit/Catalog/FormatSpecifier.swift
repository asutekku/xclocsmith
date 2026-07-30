import Foundation

/// Format specifiers inside a catalog key or translation.
///
/// A translation whose specifiers disagree with the source string is the
/// classic localization crash: `%@` where the code passes an integer reads a
/// pointer that is not there. Comparing them is the highest-value lint a
/// catalog tool can offer, and nothing in Xcode does it for you.
public struct FormatSpecifier: Equatable, Sendable {
    /// Explicit position from `%1$@`, if present.
    public let position: Int?
    /// The conversion, normalised: `@`, `d`, `f`, `s`…
    public let conversion: Character
    /// Length modifier (`ll`, `l`, `h`…), kept because `%lld` and `%d` differ.
    public let length: String
    /// The full text as written.
    public let raw: String

    /// `%lld` and `%ld` accept the same argument in Swift's bridging, but `%@`
    /// and `%lld` never do. Comparison is on conversion class, not raw text,
    /// so `%1$@` and `%@` match.
    public var conversionClass: String {
        switch conversion {
        case "@": return "object"
        case "d", "D", "i", "u", "U", "x", "X", "o", "O": return "integer"
        case "f", "F", "e", "E", "g", "G", "a", "A": return "float"
        case "c", "C": return "character"
        case "s", "S": return "cstring"
        case "p": return "pointer"
        default: return String(conversion)
        }
    }
}

public enum FormatSpecifierScanner {
    /// Matches printf-style specifiers, `%%` escapes, `%#@name@` substitution
    /// references, and `%arg` — the token Xcode writes inside a substitution's
    /// own variation values to stand for that substitution's argument.
    ///
    /// The alternatives are ordered longest-first: without `arg` ahead of the
    /// generic form, `%arg` reads as `%a` (hex float) followed by "rg", and
    /// every Belarusian plural in a real catalog reports a bogus mismatch.
    /// Deliberately narrower than C's printf grammar in two ways, because a
    /// localization catalog is full of prose containing a literal `%`:
    ///
    /// - no space flag, so "100% private" is not read as `% p`, and
    ///   "50% of max HR" is not read as `% o`;
    /// - no `%p` / `%n`, which never appear in user-facing strings.
    ///
    /// Both forms are legal C and vanishingly rare in an app's UI, while the
    /// prose that trips over them is everywhere.
    private static let pattern = try! NSRegularExpression(
        pattern: #"%(%|arg|#@[A-Za-z_][A-Za-z0-9_]*@|(?:(\d+)\$)?[-+#0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsS]))"#
    )

    public static func specifiers(in text: String) -> [FormatSpecifier] {
        let range = NSRange(text.startIndex..., in: text)
        var result: [FormatSpecifier] = []
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
            if raw == "%%" { continue }                 // literal percent
            if raw == "%arg" { continue }               // a substitution's own argument
            if raw.hasPrefix("%#@") { continue }        // substitution reference
            guard let conversionRange = Range(match.range(at: 4), in: text),
                  let conversion = text[conversionRange].first else { continue }
            let position = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
            let length = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            result.append(FormatSpecifier(position: position, conversion: conversion, length: length, raw: raw))
        }
        return result
    }

    /// Names referenced as `%#@name@`, which must exist in `substitutions`.
    public static func substitutionReferences(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
            guard raw.hasPrefix("%#@"), raw.hasSuffix("@") else { continue }
            names.append(String(raw.dropFirst(3).dropLast()))
        }
        return names
    }

    /// Replaces `%#@name@` with the specifier that substitution declares.
    static func expanding(_ text: String, with substitutions: [String: String]) -> String {
        guard !substitutions.isEmpty else { return text }
        var result = text
        for (name, specifier) in substitutions {
            let normalized = specifier.hasPrefix("%") ? specifier : "%" + specifier
            result = result.replacingOccurrences(of: "%#@\(name)@", with: normalized)
        }
        return result
    }

    public static func containsSpecifier(_ text: String) -> Bool {
        !specifiers(in: text).isEmpty || !substitutionReferences(in: text).isEmpty
    }

    /// Compares a translation against its source string.
    ///
    /// Order is ignored when the translation uses explicit positions (`%1$@`),
    /// which is exactly why positional specifiers exist — translators reorder
    /// sentences.
    ///
    /// `substitutions` maps each declared name to its `formatSpecifier`. A
    /// translation reading `%#@followers@` consumes the argument that
    /// substitution declares, so without expanding it every substitution-based
    /// translation looks like it dropped all its arguments.
    public static func mismatch(
        source: String,
        translation: String,
        substitutions: [String: String] = [:]
    ) -> String? {
        let sourceSpecifiers = specifiers(in: expanding(source, with: substitutions))
        let translationSpecifiers = specifiers(in: expanding(translation, with: substitutions))

        guard !sourceSpecifiers.isEmpty || !translationSpecifiers.isEmpty else { return nil }

        // With substitutions, an argument may be consumed inside a substitution's
        // own variation values ("%2$@ follower"), which a top-level count cannot
        // see. Counting anyway reports every correctly-authored plural as broken,
        // so the structural checks carry this case instead.
        if !substitutions.isEmpty
            || !substitutionReferences(in: source).isEmpty
            || !substitutionReferences(in: translation).isEmpty {
            return nil
        }

        if translationSpecifiers.contains(where: { $0.position != nil }) {
            for specifier in translationSpecifiers {
                guard let position = specifier.position else {
                    return "mixes positional and non-positional specifiers"
                }
                guard position >= 1, position <= sourceSpecifiers.count else {
                    return "refers to argument \(position) but the source has \(sourceSpecifiers.count)"
                }
                let expected = sourceSpecifiers[position - 1]
                if expected.conversionClass != specifier.conversionClass {
                    return "argument \(position) is \(expected.raw) in the source but \(specifier.raw) here"
                }
            }
            return nil
        }

        guard sourceSpecifiers.count == translationSpecifiers.count else {
            return "has \(translationSpecifiers.count) format specifier(s), the source has \(sourceSpecifiers.count)"
        }
        for (index, expected) in sourceSpecifiers.enumerated() {
            let actual = translationSpecifiers[index]
            if expected.conversionClass != actual.conversionClass {
                return "specifier \(index + 1) is \(expected.raw) in the source but \(actual.raw) here"
            }
        }
        return nil
    }
}
