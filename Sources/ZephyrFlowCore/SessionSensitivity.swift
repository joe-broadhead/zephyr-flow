import Foundation

/// SessionSensitivity: the confidentiality class of a dictation session
/// (contract: JOE-2241; implemented model for JOE-2258).
///
/// - `normal`: ordinary target; automatic side effects permitted under user
///   policy.
/// - `secure`: password-style field or explicitly protected target; automatic
///   persistence/clipboard/payload diagnostics are forbidden.
/// - `unknown`: sensitivity could not be established. The product FAILS CLOSED:
///   no automatic side effects may occur.
public enum SessionSensitivity: String, Codable, CaseIterable, Sendable, Equatable {
    case normal
    case secure
    case unknown

    /// Whether an automatic (non user-consented) action is allowed.
    /// Unknown fails closed; secure only allows interaction the user explicitly
    /// triggered in the review panel (handled upstream, never automatic).
    public var allowsAutomaticSideEffects: Bool {
        switch self {
        case .normal: return true
        case .secure, .unknown: return false
        }
    }

    /// History persistence gate (JOE-2259).
    public var allowsHistory: Bool { allowsAutomaticSideEffects }

    /// Clipboard fallback for automatic insertion (JOE-2259, JOE-2260).
    public var allowsClipboardFallback: Bool { allowsAutomaticSideEffects }

    /// Payload diagnostics/support-bundle inclusion (JOE-2265).
    public var allowsPayloadDiagnostics: Bool { allowsAutomaticSideEffects }

    /// Structured, text-free lifecycle metrics remain privacy-safe.
    public var allowsAnonymousMetrics: Bool { true }
}

/// Sensitivity evidence provenance: why the system believes this sensitivity.
public enum SensitivitySource: String, Codable, Sendable, Equatable {
    /// AX role inspection (e.g. AXSecureTextField).
    case accessibilityRole
    /// Target or document metadata maintained by an adapter.
    case targetMetadata
    /// User-declared policy for the target bundle.
    case userPolicy
    /// No evidence exists (=> .unknown).
    case noEvidence
}

/// A captured sensitivity determination with its evidence source.
public struct SensitivityAssessment: Sendable, Equatable {
    public let sensitivity: SessionSensitivity
    public let source: SensitivitySource
    /// Monotonic capture clock reference (continuous) for ordering.
    public let capturedAtNanos: UInt64

    public init(sensitivity: SessionSensitivity, source: SensitivitySource, capturedAtNanos: UInt64) {
        self.sensitivity = sensitivity
        self.source = source
        self.capturedAtNanos = capturedAtNanos
    }

    /// Canonical fail-closed default when no evidence exists.
    public static let unknown = SensitivityAssessment(
        sensitivity: .unknown, source: .userPolicy, capturedAtNanos: 0)
}
