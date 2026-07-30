import Foundation

/// What a literal is, once its call context is known.
public enum LiteralRole: Equatable, Sendable {
    /// A catalog key, in the given table (nil = the target's default table).
    case key(context: String, table: String?)
    /// User-visible text that will never reach a catalog.
    case bypass(reason: String)
    /// Not user-facing.
    case ignored
}

/// Localization APIs and where each one keeps its key.
///
/// Ground truth is `xcstringstool extract`: whatever the compiler writes into
/// `.stringsdata` is what ends up in the catalog. These are the call shapes it
/// recognises.
public enum LocalizableAPI {
    /// Types whose first argument is a `LocalizedStringKey` / `LocalizedStringResource`.
    public static let firstArgumentTypes: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "Stepper", "TextField",
        "SecureField", "TextEditor", "Section", "Tab", "Menu", "Link",
        "NavigationLink", "LabeledContent", "DisclosureGroup",
        "ContentUnavailableView", "GroupBox", "Slider", "Gauge", "ProgressView",
        "ShareLink", "ControlGroup", "DatePicker", "MultiDatePicker",
        "ColorPicker", "TableColumn", "Alert", "ActionSheet", "WindowGroup",
        "CommandMenu", "Settings", "LocalizedStringKey", "LocalizedStringResource",
        "NSLocalizedString",
    ]

    /// View modifiers whose first argument is localized.
    public static let modifiers: Set<String> = [
        "navigationTitle", "navigationSubtitle", "navigationBarTitle", "alert",
        "confirmationDialog", "help", "accessibilityLabel", "accessibilityHint",
        "accessibilityValue", "accessibilityInputLabels", "searchable", "badge",
        "tabItem", "dialogTitle", "fileDialogConfirmationLabel", "toolbarTitleMenu",
    ]

    /// APIs that carry the key in a labelled argument: `String(localized:)`.
    public static let labelledKey: [String: String] = [
        "String": "localized",
        "AttributedString": "localized",
    ]

    /// Argument labels that are never keys, whatever the call.
    public static let valueLabels: Set<String> = [
        "comment", "defaultValue", "tableName", "table", "bundle", "locale",
        "verbatim", "value", "format", "options", "attributes",
    ]

    /// UIKit/AppKit assignments that display text without localizing it.
    public static let assignmentTargets: Set<String> = [
        "text", "placeholder", "title", "stringValue", "attributedText",
        "toolTip", "prompt", "message", "informativeText", "headerTitle",
    ]

    /// UIKit setters that take a display string as their first argument.
    public static let uiKitSetters: Set<String> = [
        "setTitle", "setPlaceholder", "setMessage", "setPrompt",
    ]
}

public struct ClassifierOptions {
    public var localizableParams: Set<String>
    public var localizableCalls: Set<String>
    public var localizableModifiers: Set<String>
    public var skipParams: Set<String>
    public var skipCalls: Set<String>

    public init(
        localizableParams: Set<String>,
        localizableCalls: Set<String>,
        localizableModifiers: Set<String>,
        skipParams: Set<String>,
        skipCalls: Set<String>
    ) {
        self.localizableParams = localizableParams
        self.localizableCalls = localizableCalls
        self.localizableModifiers = localizableModifiers
        self.skipParams = skipParams
        self.skipCalls = skipCalls
    }
}

/// Decides what a literal is.
///
/// The rules are applied in this order, and the order is the specification —
/// not an accident of how the `if` statements happen to be arranged:
///
/// 1. A literal nested in an interpolation is a value, never a key.
/// 2. `verbatim:` is an explicit opt-out → bypass.
/// 3. Labels that are never keys (`comment:`, `defaultValue:`, `tableName:`) → ignored.
/// 4. Known localization APIs, by argument position or label → key.
/// 5. UIKit text assignments and setters → bypass (a catalog entry does not
///    make `label.text = "Hi"` localize; it needs `String(localized:)`).
/// 6. Project-declared parameters, verified against the declaring type → key.
/// 7. Configured parameter names → key.
/// 8. Anything else → ignored.
public enum Classifier {
    public static func classify(
        literal: SourceLiteral,
        context: LiteralContext,
        discovered: DiscoveredLocalizables,
        options: ClassifierOptions
    ) -> LiteralRole {
        // 1
        if literal.isNested { return .ignored }

        // 2
        if context.label == "verbatim" {
            return .bypass(reason: "Text(verbatim:) opts out of localization")
        }

        // 3
        if let label = context.label, LocalizableAPI.valueLabels.contains(label) { return .ignored }
        if let label = context.label, options.skipParams.contains(label) { return .ignored }

        // 4
        if let callee = context.callee {
            if let keyLabel = LocalizableAPI.labelledKey[callee], context.label == keyLabel {
                return .key(context: "\(callee)(\(keyLabel):)", table: context.tableName)
            }
            let isFirstArgument = context.argumentIndex == 0 && context.label == nil
            if isFirstArgument {
                if !context.isMethod,
                   LocalizableAPI.firstArgumentTypes.contains(callee) || options.localizableCalls.contains(callee) {
                    return .key(context: callee, table: context.tableName)
                }
                if context.isMethod,
                   LocalizableAPI.modifiers.contains(callee) || options.localizableModifiers.contains(callee) {
                    return .key(context: ".\(callee)", table: context.tableName)
                }
                if !context.isMethod, discovered.initializerTypes.contains(callee) {
                    return .key(context: callee, table: context.tableName)
                }
                // 5
                if context.isMethod, LocalizableAPI.uiKitSetters.contains(callee) {
                    return .bypass(reason: "\(callee)(_:) needs String(localized:) to localize")
                }
            }
        }

        // 5 (assignment form)
        if context.callee == nil, let target = context.assignmentTarget,
           LocalizableAPI.assignmentTargets.contains(target) {
            return .bypass(reason: ".\(target) = \"…\" needs String(localized:) to localize")
        }

        if let callee = context.callee, options.skipCalls.contains(callee),
           LocalizableAPI.labelledKey[callee] == nil {
            return .ignored
        }

        // 6
        if let label = context.label, let owners = discovered.parameterOwners[label], let callee = context.callee {
            if owners.contains(callee) {
                return .key(context: "\(callee)(\(label):)", table: context.tableName)
            }
            // The project declares this parameter elsewhere and this type is not
            // one of them: an internal identifier, not a display string.
            if discovered.declaredTypes.contains(callee) { return .ignored }
        }

        // 7
        if let label = context.label, options.localizableParams.contains(label) {
            let name = context.callee.map { "\($0)(\(label):)" } ?? "\(label):"
            return .key(context: name, table: context.tableName)
        }

        return .ignored
    }
}
