import Foundation

/// Every failure this tool can report. Commands throw; only the CLI layer
/// decides what to print and which status code to exit with. Nothing in the
/// library calls `exit()`, so one bad file can no longer abort a batch run.
public enum SmithError: Error, CustomStringConvertible, Equatable {
    case cannotRead(path: String, reason: String)
    case cannotWrite(path: String, reason: String)
    case invalidCatalog(path: String, reason: String)
    case invalidConfiguration(path: String, reason: String)
    case invalidPayload(path: String, reason: String)
    case noCatalogs(searchedIn: String)
    case noSources(catalog: String)
    case unknownLanguage(String, known: [String], creatable: Bool = false)
    case ambiguousLanguage(candidates: [String])
    case ambiguousCatalog(candidates: [String])
    case wouldDiscardStructure(key: String, language: String, structure: String)
    case keyNotFound(String, catalog: String)
    case invalidState(String)
    case usage(String)

    public var description: String {
        switch self {
        case .cannotRead(let path, let reason):
            return "cannot read \(path): \(reason)"
        case .cannotWrite(let path, let reason):
            return "cannot write \(path): \(reason)"
        case .invalidCatalog(let path, let reason):
            return "\(path) is not a valid string catalog: \(reason)"
        case .invalidConfiguration(let path, let reason):
            return "\(path): \(reason)"
        case .invalidPayload(let path, let reason):
            return "\(path): \(reason)"
        case .noCatalogs(let directory):
            return "no .xcstrings catalogs found under \(directory). Run `xclocsmith init` or pass a catalog path."
        case .noSources(let catalog):
            return "no source files found for \(catalog). Check `sources` in your configuration."
        case .unknownLanguage(let language, let known, let creatable):
            let catalogLanguages = known.isEmpty ? "it has none yet" : "has: \(known.joined(separator: ", "))"
            let suggestion = Self.closest(to: language, in: known)
            var message = "\"\(language)\" is not a language in this catalog (\(catalogLanguages))."
            if let suggestion { message += " Did you mean \"\(suggestion)\"?" }
            if creatable { message += " Pass --add-language to create it." }
            return message
        case .ambiguousLanguage(let candidates):
            return "this catalog has several languages (\(candidates.joined(separator: ", "))); name one with --lang"
        case .ambiguousCatalog(let candidates):
            return "several catalogs match (\(candidates.joined(separator: ", "))); name one explicitly"
        case .wouldDiscardStructure(let key, let language, let structure):
            return """
                "\(key)" [\(language)] holds \(structure) that a plain string would destroy. \
                Edit it in Xcode, or pass --flatten to overwrite it deliberately.
                """
        case .keyNotFound(let key, let catalog):
            return "\"\(key)\" is not in \(catalog). Pass --create to add it."
        case .invalidState(let state):
            return "\"\(state)\" is not a string-unit state (expected: \(TranslationState.allCases.map(\.rawValue).joined(separator: ", ")))"
        case .usage(let message):
            return message
        }
    }

    private static func closest(to input: String, in candidates: [String]) -> String? {
        candidates
            .map { ($0, Similarity.percent(input.lowercased(), $0.lowercased())) }
            .filter { $0.1 >= 60 }
            .max { $0.1 < $1.1 }?
            .0
    }
}

/// Errors that should not stop a batch: one unreadable catalog still lets the
/// others be reported.
public struct DiagnosticError: Equatable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}
