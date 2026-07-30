import Foundation

/// An `.xcstrings` file, loaded whole.
///
/// Fields this tool does not understand are carried through untouched, and
/// writes merge into the existing structure rather than replacing it: a
/// localization can hold a `stringUnit` *and* `substitutions`, and replacing
/// the object wholesale silently deletes the plural arguments a translator
/// authored in Xcode.
public struct Catalog {
    /// Absolute path with symlinks resolved, so an atomic write replaces the
    /// real file instead of turning a symlink into a regular file.
    public let path: String
    public let displayPath: String
    public let kind: CatalogKind

    /// Read-only from outside: every mutation goes through the guarded methods
    /// below, so no caller can bypass the checks that keep a catalog valid.
    public private(set) var strings: [String: JSONValue]
    private var otherFields: [String: JSONValue]

    public var sourceLanguage: String { otherFields["sourceLanguage"]?.stringValue ?? "en" }

    // MARK: - Loading

    public init(path: String, displayPath: String? = nil) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        } catch {
            throw SmithError.cannotRead(path: displayPath ?? path, reason: error.localizedDescription)
        }
        try self.init(data: data, path: resolved, displayPath: displayPath ?? path)
    }

    /// A catalog that is not on disk — a git blob being compared against the
    /// working tree, say. `path` still names where it belongs, so findings can
    /// point somewhere; nothing here writes.
    public init(data: Data, path: String, displayPath: String? = nil) throws {
        let resolved = path

        let document: JSONValue
        do {
            document = try JSONParser.parse(data)
        } catch let error as JSONParseError {
            throw SmithError.invalidCatalog(path: displayPath ?? path, reason: error.description)
        }

        guard var fields = document.objectValue else {
            throw SmithError.invalidCatalog(path: displayPath ?? path, reason: "top level is not a JSON object")
        }
        guard let strings = fields.removeValue(forKey: "strings")?.objectValue else {
            throw SmithError.invalidCatalog(path: displayPath ?? path, reason: "missing a \"strings\" object")
        }

        self.path = resolved
        self.displayPath = displayPath ?? path
        self.kind = CatalogKind(fileName: URL(fileURLWithPath: path).lastPathComponent)
        self.strings = strings
        self.otherFields = fields
    }

    /// For tests and `init`, which build catalogs in memory.
    public init(path: String, displayPath: String? = nil, sourceLanguage: String, strings: [String: JSONValue] = [:]) {
        self.path = path
        self.displayPath = displayPath ?? path
        self.kind = CatalogKind(fileName: URL(fileURLWithPath: path).lastPathComponent)
        self.strings = strings
        self.otherFields = ["sourceLanguage": .string(sourceLanguage), "version": .string("1.0")]
    }

    // MARK: - Saving

    public func serialized() -> String {
        var fields = otherFields
        fields["strings"] = .object(strings)
        if fields["version"] == nil { fields["version"] = .string("1.0") }
        return JSONWriter.text(.object(fields), style: .xcode)
    }

    public func save() throws {
        do {
            try serialized().write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SmithError.cannotWrite(path: displayPath, reason: error.localizedDescription)
        }
    }

    // MARK: - Reading

    public var keys: [String] { Array(strings.keys) }

    public func contains(_ key: String) -> Bool { strings[key] != nil }

    public func entry(_ key: String) -> [String: JSONValue]? { strings[key]?.objectValue }

    public func comment(_ key: String) -> String? { entry(key)?["comment"]?.stringValue }

    public func extractionState(_ key: String) -> ExtractionState? {
        entry(key)?["extractionState"]?.stringValue.flatMap(ExtractionState.init(rawValue:))
    }

    /// Xcode's per-key opt-out; `false` means "leave this string alone".
    public func shouldTranslate(_ key: String) -> Bool {
        entry(key)?["shouldTranslate"]?.boolValue ?? true
    }

    /// Every language appearing anywhere in the catalog, sorted.
    public var languages: [String] {
        var found = Set<String>()
        for value in strings.values {
            guard let localizations = value.objectValue?["localizations"]?.objectValue else { continue }
            found.formUnion(localizations.keys)
        }
        return found.sorted()
    }

    public func localization(_ key: String, _ language: String) -> [String: JSONValue]? {
        entry(key)?["localizations"]?.objectValue?[language]?.objectValue
    }

    public func value(_ key: String, _ language: String) -> String? {
        localization(key, language)?["stringUnit"]?.objectValue?["value"]?.stringValue
    }

    /// The text this key actually shows, for checks that reason about wording
    /// rather than structure.
    ///
    /// A pluralised key has no flat value — its text lives in the `other`
    /// variation. Returning nil for those and letting the caller fall back to
    /// the key is what made `plural.count.vote` and `plural.count.voter` look
    /// like near-duplicates: they share a namespace, and the strings they
    /// render ("%lld votes", "%lld voters") were never compared at all.
    /// A key varying by device has no `plural.other` and no one right answer —
    /// `settings.display.section.platform` is "iPhone", "iPad", "Mac" and
    /// "Apple Vision" at once. The lowest path in sort order is picked, which is
    /// arbitrary but **stable**: the first entry of an unordered walk is not,
    /// and two catalogs parsed separately then disagree about what the same
    /// unchanged key says. That is not hypothetical — it made `diff` report
    /// IceCubesApp's platform heading as having changed from "iPhone" to "Mac",
    /// with five translations stranded, when nothing had changed at all.
    public func displayText(_ key: String, _ language: String) -> String? {
        if let flat = value(key, language) { return flat }
        let entries = comparableEntries(key, language)
        return entries.first(where: { $0.path.hasSuffix("plural.other") })?.value
            ?? entries.min(by: { $0.path < $1.path })?.value
    }

    /// Every value this key holds for a language, keyed by variation path.
    ///
    /// The comparison to use when the question is "did this change", rather
    /// than "what does it say": a key with four device variations changes when
    /// any one of them does, and reducing it to a single display string both
    /// misses three of those and invents changes that did not happen.
    public func signature(_ key: String, _ language: String) -> [String: String] {
        Dictionary(comparableEntries(key, language), uniquingKeysWith: { first, _ in first })
    }

    public func shape(_ key: String, _ language: String) -> LocalizationShape {
        guard let localization = localization(key, language) else {
            return LocalizationShape(hasStringUnit: false, hasVariations: false, hasSubstitutions: false)
        }
        return LocalizationShape(
            hasStringUnit: localization["stringUnit"] != nil,
            hasVariations: localization["variations"] != nil,
            hasSubstitutions: localization["substitutions"] != nil
        )
    }

    /// Where a (key, language) pair stands, judged against the plural
    /// categories the language actually requires.
    public func status(_ key: String, _ language: String) -> TranslationStatus {
        guard let localization = localization(key, language) else { return .missing }

        if let unit = localization["stringUnit"]?.objectValue {
            let value = unit["value"]?.stringValue ?? ""
            if value.isEmpty { return .empty }
            let state = unit["state"]?.stringValue.flatMap(TranslationState.init(rawValue:)) ?? .new
            return .unit(state)
        }

        if localization["variations"] != nil || localization["substitutions"] != nil {
            return .variations(missingCategories: missingPluralCategories(localization, language: language))
        }
        return .missing
    }

    /// True when this language's entry carries plural variations, at the top
    /// level or inside a substitution.
    public func isPluralised(_ key: String, _ language: String) -> Bool {
        guard let localization = localization(key, language) else { return false }
        func walk(_ value: JSONValue) -> Bool {
            guard case .object(let fields) = value else { return false }
            if fields["variations"]?.objectValue?["plural"] != nil { return true }
            return fields.values.contains { walk($0) }
        }
        return walk(.object(localization))
    }

    /// Required CLDR categories that are absent, or present with an empty value.
    /// Device variations are checked for `other`, which is the only guaranteed key.
    private func missingPluralCategories(_ localization: [String: JSONValue], language: String) -> [String] {
        var missing: [String] = []
        let required = PluralRules.categories(for: language).required

        func walk(_ value: JSONValue) {
            guard case .object(let fields) = value else { return }

            if let plural = fields["plural"]?.objectValue {
                for category in required {
                    guard let entry = plural[category] else {
                        missing.append(category)
                        continue
                    }
                    if !Catalog.holdsText(entry) { missing.append("\(category) (empty)") }
                }
            }
            if let device = fields["device"]?.objectValue, device["other"] == nil {
                missing.append("device.other")
            }
            for nested in fields.values { walk(nested) }
        }

        walk(.object(localization))
        // A substitutions-only localization with a filled stringUnit is complete.
        if missing.isEmpty, !Catalog.holdsText(.object(localization)) { missing.append("other") }
        return missing
    }

    private static func holdsText(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            if let unit = fields["stringUnit"]?.objectValue,
               !(unit["value"]?.stringValue ?? "").isEmpty {
                return true
            }
            return fields.values.contains { holdsText($0) }
        case .array(let items):
            return items.contains { holdsText($0) }
        default:
            return false
        }
    }

    /// Comparable values with the path that identifies each one: `""` for a flat
    /// translation, `"plural.one"` for a variation.
    ///
    /// The path matters because a plural category is compared against the *same*
    /// category in the source language. English "1 new post" is German "Ein neuer
    /// Beitrag" — the singular spells the number out and carries no specifier at
    /// all, which is correct and is not a mismatch.
    public func comparableEntries(_ key: String, _ language: String) -> [(path: String, value: String)] {
        guard var localization = localization(key, language) else { return [] }
        localization.removeValue(forKey: "substitutions")

        var entries: [(String, String)] = []
        // The shape is `variations.<kind>.<category>` holding a `stringUnit`,
        // and a category may itself hold further variations. Walking it
        // generically descended into the `stringUnit` object instead of
        // recognising the category as the thing that carries the text, so no
        // plural variation was ever collected — and a German `other` form that
        // had dropped its `%lld` reported clean.
        func walk(_ value: JSONValue, path: String) {
            guard case .object(let fields) = value else { return }
            if let unit = fields["stringUnit"]?.objectValue, let text = unit["value"]?.stringValue {
                entries.append((path, text))
            }
            guard let variations = fields["variations"]?.objectValue else { return }
            for (kind, cases) in variations {
                guard let cases = cases.objectValue else { continue }
                for (category, entry) in cases {
                    walk(entry, path: path.isEmpty ? "\(kind).\(category)" : "\(path).\(kind).\(category)")
                }
            }
        }
        walk(.object(localization), path: "")
        return entries
    }

    /// Values that must carry the same format specifiers as the key: the flat
    /// translation and each plural/device variation of it.
    ///
    /// Values *inside* `substitutions` are excluded: they render one argument
    /// each and carry the specifier declared by that substitution, not the ones
    /// in the key. Comparing them against the key reports a mismatch on every
    /// correctly-authored plural.
    public func comparableValues(_ key: String, _ language: String) -> [String] {
        guard var localization = localization(key, language) else { return [] }
        localization.removeValue(forKey: "substitutions")
        var values: [String] = []
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let fields):
                if let unit = fields["stringUnit"]?.objectValue, let text = unit["value"]?.stringValue {
                    values.append(text)
                }
                for nested in fields.values { walk(nested) }
            case .array(let items):
                items.forEach(walk)
            default:
                break
            }
        }
        walk(.object(localization))
        return values
    }

    /// Substitutions declared for a (key, language), by name.
    public func substitutions(_ key: String, _ language: String) -> [String: JSONValue] {
        localization(key, language)?["substitutions"]?.objectValue ?? [:]
    }

    /// Each declared substitution's `formatSpecifier`, by name.
    public func substitutionSpecifiers(_ key: String, _ language: String) -> [String: String] {
        substitutions(key, language).compactMapValues { $0.objectValue?["formatSpecifier"]?.stringValue }
    }

    /// Problems in the substitution structure itself.
    ///
    /// Only the unambiguous ones: a `%#@name@` reference nothing declares, and a
    /// declared substitution nothing references. Comparing the specifiers *inside*
    /// a substitution against the one it declares looks tempting and is wrong —
    /// those values legitimately contain `%arg` for the substitution's own
    /// argument and `%2$@` for other arguments of the outer string.
    public func substitutionProblems(_ key: String, _ language: String) -> [String] {
        let declared = substitutions(key, language)
        var referenced = Set<String>()
        for value in comparableValues(key, language) {
            referenced.formUnion(FormatSpecifierScanner.substitutionReferences(in: value))
        }
        guard !declared.isEmpty || !referenced.isEmpty else { return [] }

        var problems: [String] = []
        for name in referenced.sorted() where declared[name] == nil {
            problems.append("references %#@\(name)@ but no substitution declares it")
        }
        for name in declared.keys.sorted() where !referenced.contains(name) {
            problems.append("declares substitution \"\(name)\" that no value references")
        }
        return problems
    }

    // MARK: - Writing

    @discardableResult
    public mutating func register(_ key: String, extractionState: ExtractionState?) -> Bool {
        guard strings[key] == nil else { return false }
        var entry: [String: JSONValue] = [:]
        if let extractionState { entry["extractionState"] = .string(extractionState.rawValue) }
        strings[key] = .object(entry)
        return true
    }

    public mutating func setComment(_ comment: String, for key: String) {
        var entry = strings[key]?.objectValue ?? [:]
        entry["comment"] = .string(comment)
        strings[key] = .object(entry)
    }

    /// Writes a flat translation.
    ///
    /// Throws rather than destroying plural variations or substitutions unless
    /// `flatten` is set: those structures cannot be reconstructed from a plain
    /// string, and losing them breaks formatting at runtime.
    @discardableResult
    public mutating func setTranslation(
        key: String,
        language: String,
        value: String,
        state: TranslationState,
        flatten: Bool = false
    ) throws -> Bool {
        let existingShape = shape(key, language)
        if let structure = existingShape.structureDescription, !flatten {
            throw SmithError.wouldDiscardStructure(key: key, language: language, structure: structure)
        }

        var entry = strings[key]?.objectValue ?? [:]
        var localizations = entry["localizations"]?.objectValue ?? [:]
        let existed = localizations[language] != nil

        // Merge into the existing localization so unknown sibling fields survive.
        var localization = localizations[language]?.objectValue ?? [:]
        if flatten {
            localization.removeValue(forKey: "variations")
            localization.removeValue(forKey: "substitutions")
        }
        localization["stringUnit"] = .object([
            "state": .string(state.rawValue),
            "value": .string(value),
        ])

        localizations[language] = .object(localization)
        entry["localizations"] = .object(localizations)
        strings[key] = .object(entry)
        return existed
    }

    /// Writes one plural category, creating the variation structure if needed.
    /// This is the only way to author plurals outside Xcode.
    ///
    /// Guarded like `setTranslation`: a localization that carries substitutions
    /// keeps its plurals *inside* them, so writing a top-level plural would both
    /// delete the translator's sentence frame and leave a shape Xcode never
    /// writes. Replacing an existing flat translation is refused for the same
    /// reason — it is a translation being discarded.
    public mutating func setPluralTranslation(
        key: String,
        language: String,
        category: String,
        value: String,
        state: TranslationState,
        flatten: Bool = false
    ) throws {
        if !flatten {
            let existing = shape(key, language)
            if existing.hasSubstitutions {
                throw SmithError.wouldDiscardStructure(
                    key: key, language: language,
                    structure: "substitutions (%#@name@ arguments), whose plurals live inside them"
                )
            }
            if existing.hasStringUnit, !(self.value(key, language) ?? "").isEmpty {
                throw SmithError.wouldDiscardStructure(
                    key: key, language: language,
                    structure: "a translation that varying by plural would replace"
                )
            }
        }
        var entry = strings[key]?.objectValue ?? [:]
        var localizations = entry["localizations"]?.objectValue ?? [:]
        var localization = localizations[language]?.objectValue ?? [:]
        var variations = localization["variations"]?.objectValue ?? [:]
        var plural = variations["plural"]?.objectValue ?? [:]

        var categoryEntry = plural[category]?.objectValue ?? [:]
        categoryEntry["stringUnit"] = .object([
            "state": .string(state.rawValue),
            "value": .string(value),
        ])
        plural[category] = .object(categoryEntry)
        variations["plural"] = .object(plural)
        localization["variations"] = .object(variations)
        // A localization carries either a stringUnit or variations, not both.
        localization.removeValue(forKey: "stringUnit")
        localizations[language] = .object(localization)
        entry["localizations"] = .object(localizations)
        strings[key] = .object(entry)
    }

    /// Writes one device variation (`iphone`, `ipad`, `mac`, `other`, …).
    public mutating func setDeviceTranslation(
        key: String,
        language: String,
        device: String,
        value: String,
        state: TranslationState
    ) {
        var entry = strings[key]?.objectValue ?? [:]
        var localizations = entry["localizations"]?.objectValue ?? [:]
        var localization = localizations[language]?.objectValue ?? [:]
        var variations = localization["variations"]?.objectValue ?? [:]
        var devices = variations["device"]?.objectValue ?? [:]

        var deviceEntry = devices[device]?.objectValue ?? [:]
        deviceEntry["stringUnit"] = .object([
            "state": .string(state.rawValue),
            "value": .string(value),
        ])
        devices[device] = .object(deviceEntry)
        variations["device"] = .object(devices)
        localization["variations"] = .object(variations)
        localization.removeValue(forKey: "stringUnit")
        localizations[language] = .object(localization)
        entry["localizations"] = .object(localizations)
        strings[key] = .object(entry)
    }

    /// Writes one plural case inside an existing substitution.
    ///
    /// Returns `false` when no such substitution is declared: creating one needs
    /// an `argNum` and a `formatSpecifier` that an XLIFF unit does not carry,
    /// and inventing them would produce a catalog Xcode cannot format.
    @discardableResult
    public mutating func setSubstitutionPluralTranslation(
        key: String,
        language: String,
        substitution: String,
        category: String,
        value: String,
        state: TranslationState
    ) -> Bool {
        guard var entry = strings[key]?.objectValue,
              var localizations = entry["localizations"]?.objectValue,
              var localization = localizations[language]?.objectValue,
              var substitutions = localization["substitutions"]?.objectValue,
              var target = substitutions[substitution]?.objectValue else {
            return false
        }

        var variations = target["variations"]?.objectValue ?? [:]
        var plural = variations["plural"]?.objectValue ?? [:]
        var categoryEntry = plural[category]?.objectValue ?? [:]
        categoryEntry["stringUnit"] = .object([
            "state": .string(state.rawValue),
            "value": .string(value),
        ])
        plural[category] = .object(categoryEntry)
        variations["plural"] = .object(plural)
        target["variations"] = .object(variations)
        substitutions[substitution] = .object(target)
        localization["substitutions"] = .object(substitutions)
        localizations[language] = .object(localization)
        entry["localizations"] = .object(localizations)
        strings[key] = .object(entry)
        return true
    }

    public mutating func remove(_ key: String) {
        strings.removeValue(forKey: key)
    }
}
