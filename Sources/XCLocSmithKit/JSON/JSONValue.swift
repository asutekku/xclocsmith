import Foundation

/// A JSON tree that preserves every field it does not understand.
///
/// String catalogs gain fields as Xcode evolves (`substitutions`, device
/// variations, whatever comes next). Decoding into a fixed Swift model would
/// drop them on the next write, so this type keeps the document whole and lets
/// callers reach into the parts they know about.
///
/// Numbers keep their original spelling: re-emitting `1.0` as `1` would be a
/// gratuitous diff in someone's repository.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value } else { return nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value } else { return nil }
    }

    public var intValue: Int? {
        if case .number(let raw) = self { return Int(raw) } else { return nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value } else { return nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value } else { return nil }
    }

    /// A list of strings from either an array of strings or a single string.
    /// Configuration files are friendlier when `"sources": "App"` also works.
    public var stringList: [String]? {
        if let single = stringValue { return [single] }
        guard let items = arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
