import Foundation

/// The `add` input format, and the templates `check`/`scan` write.
///
/// Templates carry their own catalog and language, so applying one cannot
/// misfile translations into the wrong catalog or under the wrong locale — the
/// two mistakes that are hardest to notice afterwards, because every later
/// check reports them as done.
///
/// ```json
/// {
///   "format": "xclocsmith/v1",
///   "catalog": "App/Localizable.xcstrings",
///   "language": "ja",
///   "strings": {
///     "Save": "保存",
///     "Detailed": { "value": "…", "state": "needs_review", "comment": "…" },
///     "%lld items": { "plural": { "one": "…", "other": "…" } }
///   }
/// }
/// ```
///
/// A bare `{"key": "value"}` object is also accepted, in which case `--lang`
/// and the catalog must be supplied on the command line.
public struct TranslationPayload {
    public static let formatIdentifier = "xclocsmith/v1"
    public static let todoMarker = "TODO"

    public enum Entry: Equatable {
        case simple(String)
        case detailed(value: String, state: TranslationState?, comment: String?)
        case plural([String: String])

        public var isTodo: Bool {
            switch self {
            case .simple(let value): return value == TranslationPayload.todoMarker
            case .detailed(let value, _, _): return value == TranslationPayload.todoMarker
            case .plural(let forms): return forms.values.allSatisfy { $0 == TranslationPayload.todoMarker }
            }
        }
    }

    public var catalog: String?
    public var language: String?
    public var entries: [String: Entry]

    public init(catalog: String?, language: String?, entries: [String: Entry]) {
        self.catalog = catalog
        self.language = language
        self.entries = entries
    }

    public static func load(from data: Data, path: String) throws -> TranslationPayload {
        let document: JSONValue
        do {
            document = try JSONParser.parse(data)
        } catch let error as JSONParseError {
            throw SmithError.invalidPayload(path: path, reason: error.description)
        }
        return try load(from: document, path: path)
    }

    public static func load(from document: JSONValue, path: String) throws -> TranslationPayload {
        guard let fields = document.objectValue else {
            throw SmithError.invalidPayload(path: path, reason: "top level must be a JSON object")
        }

        if fields["format"]?.stringValue == formatIdentifier {
            guard let strings = fields["strings"]?.objectValue else {
                throw SmithError.invalidPayload(path: path, reason: "missing a \"strings\" object")
            }
            return TranslationPayload(
                catalog: fields["catalog"]?.stringValue,
                language: fields["language"]?.stringValue,
                entries: try parseEntries(strings, path: path)
            )
        }

        if fields["format"] != nil {
            throw SmithError.invalidPayload(
                path: path,
                reason: "unknown \"format\" (expected \"\(formatIdentifier)\")"
            )
        }
        return TranslationPayload(catalog: nil, language: nil, entries: try parseEntries(fields, path: path))
    }

    private static func parseEntries(_ fields: [String: JSONValue], path: String) throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for (key, value) in fields {
            switch value {
            case .string(let text):
                entries[key] = .simple(text)
            case .object(let detail):
                if let plural = detail["plural"]?.objectValue {
                    var forms: [String: String] = [:]
                    for (category, form) in plural {
                        guard let text = form.stringValue else {
                            throw SmithError.invalidPayload(
                                path: path,
                                reason: "\"\(key)\".plural.\(category) must be a string"
                            )
                        }
                        guard PluralRules.allCategories.contains(category) else {
                            throw SmithError.invalidPayload(
                                path: path,
                                reason: "\"\(category)\" is not a plural category (expected \(PluralRules.allCategories.joined(separator: ", ")))"
                            )
                        }
                        forms[category] = text
                    }
                    entries[key] = .plural(forms)
                    continue
                }
                guard let text = detail["value"]?.stringValue else {
                    throw SmithError.invalidPayload(path: path, reason: "\"\(key)\" needs a \"value\" or \"plural\"")
                }
                var state: TranslationState?
                if let raw = detail["state"]?.stringValue {
                    guard let parsed = TranslationState(rawValue: raw) else {
                        throw SmithError.invalidState(raw)
                    }
                    state = parsed
                }
                entries[key] = .detailed(value: text, state: state, comment: detail["comment"]?.stringValue)
            default:
                throw SmithError.invalidPayload(
                    path: path,
                    reason: "\"\(key)\" must be a string or an object"
                )
            }
        }
        return entries
    }

    /// Writes a `"TODO"` template ready to be filled in and applied.
    ///
    /// A key the source pluralises is written as the plural shape the *target*
    /// language needs, not as a flat `"TODO"`:
    ///
    /// ```json
    /// "%lld items": { "plural": { "one": "TODO", "few": "TODO",
    ///                             "many": "TODO", "other": "TODO" } }
    /// ```
    ///
    /// Whoever fills this in — a translator or a model — cannot be expected to
    /// know that Russian needs four forms and Japanese one. Asking for a flat
    /// string and then failing the result is a worse tool than asking for the
    /// right shape in the first place.
    public static func writeTemplate(
        keys: [String],
        catalog: String,
        language: String,
        pluralKeys: Set<String> = [],
        sources: [String: String] = [:],
        comments: [String: String] = [:],
        to path: String
    ) throws {
        let document = makeTemplate(
            keys: keys,
            catalog: catalog,
            language: language,
            pluralKeys: pluralKeys,
            sources: sources,
            comments: comments
        )
        do {
            try JSONWriter.text(document, style: .plain).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SmithError.cannotWrite(path: path, reason: error.localizedDescription)
        }
    }

    /// The template as a value, for callers with nowhere to put a file.
    ///
    /// The MCP server hands this straight to a model: an agent has no working
    /// directory to write into and no reason to round-trip through one, but it
    /// needs the same shape a translator gets — four plural rows for Russian and
    /// one for Japanese, decided here rather than guessed there.
    public static func makeTemplate(
        keys: [String],
        catalog: String,
        language: String,
        pluralKeys: Set<String> = [],
        sources: [String: String] = [:],
        comments: [String: String] = [:]
    ) -> JSONValue {
        var strings: [String: JSONValue] = [:]
        for key in keys {
            // `source` is read-only context, and `add` ignores it. It is
            // emitted only when the key is not itself the English string: a
            // project keyed by identifier writes `notifications.label.favorite
            // %lld`, and without its value — "starred" — the template asks for
            // a translation of a string the translator has never seen.
            var entry: [String: JSONValue] = [:]
            if let source = sources[key], source != key { entry["source"] = .string(source) }
            if let comment = comments[key], !comment.isEmpty { entry["comment"] = .string(comment) }

            if pluralKeys.contains(key) {
                var categories: [String: JSONValue] = [:]
                for category in PluralRules.categories(for: language).required {
                    categories[category] = .string(todoMarker)
                }
                entry["plural"] = .object(categories)
            } else if entry.isEmpty {
                // Nothing to say about it: the short form stays short.
                strings[key] = .string(todoMarker)
                continue
            } else {
                entry["value"] = .string(todoMarker)
            }
            strings[key] = .object(entry)
        }
        return JSONValue.object([
            "format": .string(formatIdentifier),
            "catalog": .string(catalog),
            "language": .string(language),
            "strings": .object(strings),
        ])
    }
}


/// Where translation templates are written.
///
/// With more than one (catalog, language) pair the name is disambiguated, so a
/// caller that passes `--out work.json` and reads exactly that path is not left
/// with a file that silently holds only part of the work.
public enum TemplateNaming {
    public static func path(base: String, catalog: String, language: String, disambiguate: Bool) -> String {
        guard disambiguate else { return base }
        let slug = catalog
            .replacingOccurrences(of: ".xcstrings", with: "")
            .replacingOccurrences(of: "/", with: "-")
        let dot = base.lastIndex(of: ".")
        let stem = dot.map { String(base[..<$0]) } ?? base
        let ext = dot.map { String(base[base.index(after: $0)...]) } ?? "json"
        return "\(stem)-\(slug)-\(language).\(ext)"
    }
}
