import Foundation

/// Project-specific localization conventions, learned from the source itself.
///
/// A view that takes a `String` and renders it through `LocalizedStringKey`
/// makes its call sites localizable: `StatRow(label: "Best Drop")` is a catalog
/// key even though `label:` means nothing to SwiftUI. The same parameter name
/// on a type that does *not* do that is an internal identifier, so the owning
/// type is recorded and checked at the call site.
public struct DiscoveredLocalizables: Equatable, Sendable {
    /// Parameter name → types that localize it.
    public var parameterOwners: [String: Set<String>] = [:]
    /// Types whose first unlabelled initializer argument is localized.
    public var initializerTypes: Set<String> = []
    /// Every type declared in the scanned sources, so an unknown callee can be
    /// distinguished from one we know does not localize.
    public var declaredTypes: Set<String> = []

    public init() {}
}

enum LocalizableDiscovery {
    private static let typeDeclaration = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:struct|final class|class|actor|enum|extension)\s+([A-Z][A-Za-z0-9_]*)"#
    )
    private static let stringProperty = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*String\b"#
    )
    private static let localizedProperty = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*(?:LocalizedStringKey|LocalizedStringResource)\b"#
    )
    private static let localizedUse = try! NSRegularExpression(
        pattern: #"(?:LocalizedStringKey|LocalizedStringResource)\(\s*([A-Za-z_][A-Za-z0-9_.]*)"#
    )
    private static let unlabelledInit = try! NSRegularExpression(
        pattern: #"init\(\s*_\s+([a-z_][A-Za-z0-9_]*)\s*:\s*(?:String|LocalizedStringKey)\b"#
    )

    /// Scans the comment-stripped code of every file.
    static func discover(in files: [AnalyzedSource]) -> DiscoveredLocalizables {
        var result = DiscoveredLocalizables()

        for file in files {
            let code = String(file.lexed.code)
            var currentType: String?
            var typeDepth = 0
            var depth = 0
            var stringProperties = Set<String>()
            var localizedProperties = Set<String>()
            var localizedArguments = Set<String>()
            var unlabelledFirstParameters = Set<String>()

            func flush() {
                guard let type = currentType else { return }
                let localizable = stringProperties
                    .intersection(localizedArguments)
                    .union(localizedProperties)
                for parameter in localizable {
                    result.parameterOwners[parameter, default: []].insert(type)
                }
                if !unlabelledFirstParameters.isDisjoint(with: localizable) {
                    result.initializerTypes.insert(type)
                }
                stringProperties.removeAll()
                localizedProperties.removeAll()
                localizedArguments.removeAll()
                unlabelledFirstParameters.removeAll()
                currentType = nil
            }

            for line in splitLines(code) {
                let range = NSRange(line.startIndex..., in: line)

                if let match = typeDeclaration.firstMatch(in: line, range: range),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    flush()
                    let name = String(line[nameRange])
                    currentType = name
                    result.declaredTypes.insert(name)
                    typeDepth = depth
                }

                for character in line {
                    if character == "{" { depth += 1 }
                    if character == "}" {
                        depth -= 1
                        if currentType != nil && depth <= typeDepth { flush() }
                    }
                }

                guard currentType != nil else { continue }

                for match in stringProperty.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) { stringProperties.insert(String(line[r])) }
                }
                for match in localizedProperty.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) { localizedProperties.insert(String(line[r])) }
                }
                for match in localizedUse.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let components = String(line[r]).split(separator: ".").map(String.init)
                    if let first = components.first { localizedArguments.insert(first) }
                    if let last = components.last { localizedArguments.insert(last) }
                }
                for match in unlabelledInit.matches(in: line, range: range) {
                    if let r = Range(match.range(at: 1), in: line) {
                        unlabelledFirstParameters.insert(String(line[r]))
                    }
                }
            }
            flush()
        }
        return result
    }

    /// Property names declared as `LocalizedStringKey` anywhere in the project.
    /// Used to avoid double-wrapping and to recognise already-localized values.
    static func localizedPropertyNames(in files: [AnalyzedSource]) -> Set<String> {
        var names = Set<String>()
        for file in files {
            let code = String(file.lexed.code)
            let range = NSRange(code.startIndex..., in: code)
            for match in localizedProperty.matches(in: code, range: range) {
                if let r = Range(match.range(at: 1), in: code) { names.insert(String(code[r])) }
            }
        }
        return names
    }
}
