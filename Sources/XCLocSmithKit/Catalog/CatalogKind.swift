import Foundation

/// What a catalog is for, which decides how it may be audited.
///
/// Only `Localizable.xcstrings` and custom tables hold keys that appear in
/// source code. `InfoPlist.xcstrings` holds Info.plist keys — with modern
/// `INFOPLIST_KEY_*` build settings those never appear in the repository at
/// all — and `AppShortcuts.xcstrings` holds Siri utterances, which are
/// deliberately near-identical to each other. Treating either like a code
/// table produces advice to delete your camera usage description.
public enum CatalogKind: Equatable, Sendable {
    /// `Localizable.xcstrings` — the default table.
    case localizable
    /// A named table, reached from source with `tableName:` / `table:`.
    case table(String)
    /// `InfoPlist.xcstrings` — keys are Info.plist keys.
    case infoPlist
    /// `AppShortcuts.xcstrings` — keys are App Intents phrases.
    case appShortcuts

    public init(fileName: String) {
        let stem = fileName.hasSuffix(".xcstrings")
            ? String(fileName.dropLast(".xcstrings".count))
            : fileName
        switch stem {
        case "Localizable": self = .localizable
        case "InfoPlist": self = .infoPlist
        case "AppShortcuts": self = .appShortcuts
        default: self = .table(stem)
        }
    }

    /// The table name a call site must ask for to reach this catalog.
    /// `nil` for catalogs that source code never names.
    public var tableName: String? {
        switch self {
        case .localizable: return "Localizable"
        case .table(let name): return name
        case .infoPlist, .appShortcuts: return nil
        }
    }

    /// Whether keys in this catalog are expected to appear in source code.
    /// Drives orphan detection, `prune`, and "string not in catalog" findings.
    public var isReferencedFromSource: Bool {
        switch self {
        case .localizable, .table: return true
        case .infoPlist, .appShortcuts: return false
        }
    }

    /// App Shortcut phrases are supposed to be near-duplicates of one another.
    public var wantsSimilarKeyCheck: Bool {
        switch self {
        case .localizable, .table, .infoPlist: return true
        case .appShortcuts: return false
        }
    }

    public var displayName: String {
        switch self {
        case .localizable: return "Localizable"
        case .table(let name): return name
        case .infoPlist: return "InfoPlist"
        case .appShortcuts: return "AppShortcuts"
        }
    }
}
