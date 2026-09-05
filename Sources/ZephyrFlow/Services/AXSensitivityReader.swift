import ApplicationServices
import ZephyrFlowCore

/// Reads only role/subrole/enabled metadata from one retained handle, without
/// awaits or field values. This is NOT a bounded IPC or atomic-focus guarantee.
enum AXSensitivityReader {
    struct Evidence: Sendable {
        let role: AccessibilityStringEvidence
        let subrole: AccessibilityStringEvidence
        let enabled: Bool?
        var sensitivity: SessionSensitivity {
            AccessibilitySensitivity.classify(role: role, subrole: subrole, enabled: enabled)
        }
        var editable: Bool { role.value.map { AccessibilitySensitivity.textLikeRoles.contains($0) } ?? false }
    }

    static func read(_ element: AXUIElement) -> Evidence {
        readAttributes { attribute in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (error, value)
        }
    }

    /// Injection exercises the actual native-error/type mapping without AX
    /// messages, target apps or Accessibility permission requests in tests.
    static func readAttributes(_ read: (String) -> (AXError, CFTypeRef?)) -> Evidence {
        let role = string(read(kAXRoleAttribute))
        let subrole = string(read(kAXSubroleAttribute))
        let (error, value) = read(kAXEnabledAttribute)
        let enabled: Bool?
        if error == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() {
            enabled = CFEqual(value, kCFBooleanTrue)
        } else {
            enabled = nil
        }
        return Evidence(role: role, subrole: subrole, enabled: enabled)
    }

    private static func string(_ reply: (AXError, CFTypeRef?)) -> AccessibilityStringEvidence {
        switch reply.0 {
        case .attributeUnsupported, .noValue: return .notPresent
        case .success:
            guard let value = reply.1, CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
                return .unavailable
            }
            return .value(text)
        default: return .unavailable
        }
    }
}
