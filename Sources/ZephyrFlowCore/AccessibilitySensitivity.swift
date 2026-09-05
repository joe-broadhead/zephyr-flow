import Foundation

/// A missing optional AX attribute is different from an IPC/read/type error.
/// Read errors must not silently become evidence of an ordinary text field.
public enum AccessibilityStringEvidence: Sendable, Equatable {
    case value(String)
    case notPresent
    case unavailable

    public var value: String? {
        if case .value(let value) = self { return value }
        return nil
    }
}

public enum AccessibilitySensitivity {
    public static let textLikeRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXTextView", "AXSearchField",
    ]

    public static func classify(
        role: AccessibilityStringEvidence, subrole: AccessibilityStringEvidence,
        enabled: Bool?
    ) -> SessionSensitivity {
        if InsertionStrategyResolver.isSecureRole(role.value) || InsertionStrategyResolver.isSecureRole(subrole.value) {
            return .secure
        }
        guard let role = role.value, textLikeRoles.contains(role), subrole != .unavailable, enabled == true else {
            return .unknown
        }
        return .normal
    }
}
