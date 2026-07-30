import Foundation

/// One `<trans-unit>` from an XLIFF 1.2 file.
public struct XLIFFUnit: Equatable, Sendable {
    public let id: String
    public let source: String
    /// `nil` when the unit has no `<target>` at all, which is how an
    /// untranslated string comes back from a localizer.
    public let target: String?
    public let note: String?
    /// XLIFF `state`: `new`, `needs-translation`, `needs-review-translation`,
    /// `translated`, `final`, `signed-off`.
    public let state: String?
    /// XLIFF `state-qualifier`. Xcode's own agent workflow writes
    /// `leveraged-mt` for machine translation.
    public let stateQualifier: String?
    public let line: Int

    public var isTranslated: Bool {
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    public var isMachineTranslated: Bool {
        guard let stateQualifier else { return false }
        return stateQualifier.contains("mt")
    }
}

/// One `<file>` element. Xcode emits one per string table.
public struct XLIFFFile: Equatable, Sendable {
    public let original: String
    public let sourceLanguage: String
    public let targetLanguage: String?
    public let datatype: String?
    public let units: [XLIFFUnit]

    /// The table this file carries.
    ///
    /// Xcode names the file after the table with a `.strings` extension even
    /// when the strings came from a `.xcstrings`, so `MyApp/Buttons.strings`
    /// is the `Buttons` table and `Localizable.strings` is the default one.
    public var table: String {
        let name = (original as NSString).lastPathComponent
        for suffix in [".strings", ".stringsdict", ".xcstrings"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? "Localizable" : name
    }
}

public struct XLIFFDocument: Equatable, Sendable {
    public let path: String
    public let files: [XLIFFFile]

    public var units: [XLIFFUnit] { files.flatMap(\.units) }
}

/// Parses XLIFF 1.2 as Xcode writes it.
///
/// Deliberately conservative: inline markup inside `<source>`/`<target>`
/// (`<g>`, `<x/>`, `<ph>`) is recorded as a problem rather than flattened,
/// because silently dropping a placeholder tag would produce a translation
/// missing an argument.
public enum XLIFFParser {
    public static func parse(contentsOf path: String) throws -> XLIFFDocument {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SmithError.cannotRead(path: path, reason: "unreadable")
        }
        return try parse(data: data, path: path)
    }

    public static func parse(data: Data, path: String) throws -> XLIFFDocument {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            let reason = delegate.failure
                ?? parser.parserError.map { "\($0.localizedDescription) at line \(parser.lineNumber)" }
                ?? "malformed XML"
            throw SmithError.invalidPayload(path: path, reason: reason)
        }
        if let failure = delegate.failure {
            throw SmithError.invalidPayload(path: path, reason: failure)
        }
        return XLIFFDocument(path: path, files: delegate.files)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var files: [XLIFFFile] = []
        var failure: String?

        private var fileOriginal = ""
        private var fileSourceLanguage = ""
        private var fileTargetLanguage: String?
        private var fileDatatype: String?
        private var units: [XLIFFUnit] = []

        private var unitID: String?
        private var unitState: String?
        private var unitStateQualifier: String?
        private var unitLine = 0
        private var source: String?
        private var target: String?
        private var note: String?

        private var buffer = ""
        private var capturing: String?
        private var sawInlineMarkup = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "file":
                fileOriginal = attributes["original"] ?? ""
                fileSourceLanguage = attributes["source-language"] ?? ""
                fileTargetLanguage = attributes["target-language"]
                fileDatatype = attributes["datatype"]
                units = []

            case "trans-unit":
                unitID = attributes["id"]
                unitLine = parser.lineNumber
                source = nil
                target = nil
                note = nil
                unitState = nil
                unitStateQualifier = nil
                sawInlineMarkup = false

            case "source", "target", "note":
                if elementName == "target" {
                    unitState = attributes["state"]
                    unitStateQualifier = attributes["state-qualifier"]
                }
                capturing = elementName
                buffer = ""

            default:
                // Inline placeholder markup inside a captured element.
                if capturing != nil { sawInlineMarkup = true }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing != nil else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard capturing != nil else { return }
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "source": source = buffer; capturing = nil
            case "target": target = buffer; capturing = nil
            case "note": note = buffer; capturing = nil

            case "trans-unit":
                guard let unitID else { break }
                if sawInlineMarkup && failure == nil {
                    failure = "trans-unit \"\(unitID)\" contains inline markup this tool does not understand"
                }
                units.append(XLIFFUnit(
                    id: unitID,
                    source: source ?? "",
                    target: target,
                    note: note,
                    state: unitState,
                    stateQualifier: unitStateQualifier,
                    line: unitLine
                ))
                self.unitID = nil

            case "file":
                files.append(XLIFFFile(
                    original: fileOriginal,
                    sourceLanguage: fileSourceLanguage,
                    targetLanguage: fileTargetLanguage,
                    datatype: fileDatatype,
                    units: units
                ))
                units = []

            default:
                break
            }
        }
    }
}

/// How an XLIFF `state` maps onto a string catalog's `stringUnit.state`.
///
/// Machine translation is imported as `needs_review` whatever its state says:
/// Xcode's own agent workflow marks those units `state-qualifier="leveraged-mt"`,
/// and a machine translation that lands as `translated` is one nobody will ever
/// look at again.
public enum XLIFFState {
    public static func catalogState(state: String?, qualifier: String?) -> TranslationState {
        if let qualifier, qualifier.contains("mt") { return .needsReview }
        switch state {
        case "translated", "final", "signed-off": return .translated
        case "needs-review-translation", "needs-review-adaptation", "needs-review-l10n",
             "needs-adaptation", "needs-l10n": return .needsReview
        case "new", "needs-translation": return .new
        case .none: return .translated       // Xcode omits state on plain translated units
        default: return .needsReview
        }
    }
}
