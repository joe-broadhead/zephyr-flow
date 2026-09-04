import Foundation

// MARK: - Terminal outcome taxonomy (contract: JOE-2240)
//
// Every session, engine, Flow and insertion stage terminates in exactly one
// controlled outcome. This taxonomy is the authoritative vocabulary shared by
// the state machine, engines, privacy policy, metrics and UI. See
// docs/development/contracts/product-invariants.md.

public enum StageOutcomeCategory: String, Codable, CaseIterable, Sendable {
    /// Stage completed exactly as asked.
    case completed
    /// Completed but with a typed, non-fatal degradation (e.g. downmixed
    /// audio, conservative fallback backend).
    case degraded
    /// Produced a usable but incomplete result.
    case partial
    /// Input exceeded the bounded design and the result was truncated.
    case truncated
    /// Cancelled by the user or control plane before completion.
    case cancelled
    /// Terminated by a deadline/timeout; never reported as ordinary success.
    case deadlineExceeded
    /// The intended target changed identity or sensitivity.
    case targetChanged
    /// The target is secure/unknown; the stage must fail closed.
    case secureTarget
    /// The stage failed; no success-shaped result may be emitted.
    case failed
    /// Abandoned during application termination; reported honestly.
    case abandonedDuringShutdown
}

/// OutcomePolicy: which surfaces may consume an outcome.
public struct OutcomePolicy: Sendable, Equatable {
    /// May the UI render a green success state for this outcome?
    public let showsSuccessUI: Bool
    /// May this outcome be persisted to user-visible history?
    public let maySaveHistory: Bool
    /// May this outcome have caused (or represent) an automatic clipboard write?
    public let mayWriteClipboard: Bool
    /// May privacy-safe structured metrics be emitted?
    public let emitsMetrics: Bool
    /// May this outcome enter release/qualification evidence?
    public let entersReleaseEvidence: Bool

    public init(
        showsSuccessUI: Bool, maySaveHistory: Bool, mayWriteClipboard: Bool,
        emitsMetrics: Bool, entersReleaseEvidence: Bool
    ) {
        self.showsSuccessUI = showsSuccessUI
        self.maySaveHistory = maySaveHistory
        self.mayWriteClipboard = mayWriteClipboard
        self.emitsMetrics = emitsMetrics
        self.entersReleaseEvidence = entersReleaseEvidence
    }

    /// Fail-closed policy for any unknown/unmapped outcome.
    public static let failClosed = OutcomePolicy(
        showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
        emitsMetrics: false, entersReleaseEvidence: false)
}

extension OutcomePolicy {
    public static func policy(for outcome: StageOutcomeCategory) -> OutcomePolicy {
        switch outcome {
        case .completed:
            return OutcomePolicy(
                showsSuccessUI: true, maySaveHistory: true, mayWriteClipboard: true,
                emitsMetrics: true, entersReleaseEvidence: true)
        case .degraded:
            // Content was delivered but not at the requested fidelity: visible
            // but never presented as unqualified success.
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: true, mayWriteClipboard: true,
                emitsMetrics: true, entersReleaseEvidence: true)
        case .partial, .truncated:
            // Never present incomplete content as success; partial text stays
            // inert and is never silently persisted as finished dictation.
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
                emitsMetrics: true, entersReleaseEvidence: false)
        case .cancelled, .deadlineExceeded, .abandonedDuringShutdown:
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
                emitsMetrics: true, entersReleaseEvidence: false)
        case .targetChanged:
            // The text is real but never reached its intended destination.
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
                emitsMetrics: true, entersReleaseEvidence: true)
        case .secureTarget:
            // Privacy confinement: no history, no clipboard, no payload evidence.
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
                emitsMetrics: false, entersReleaseEvidence: false)
        case .failed:
            return OutcomePolicy(
                showsSuccessUI: false, maySaveHistory: false, mayWriteClipboard: false,
                emitsMetrics: true, entersReleaseEvidence: false)
        }
    }
}

/// Exactly-one terminal guard: a stage terminates once; duplicate/late
/// completion attempts are rejected (JOE-2240, JOE-2242).
public actor SessionTerminalGate {
    private var recorded: StageOutcomeCategory?
    private var recordedAt: ContinuousClock.Instant?

    public init() {}

    /// Returns `true` when this call recorded the terminal outcome (first
    /// acceptance) and `false` for duplicate/late attempts.
    public func record(_ outcome: StageOutcomeCategory) -> Bool {
        guard recorded == nil else { return false }
        recorded = outcome
        recordedAt = ContinuousClock.now
        return true
    }

    public var terminalState: (outcome: StageOutcomeCategory, at: ContinuousClock.Instant)? {
        guard let recorded, let recordedAt else { return nil }
        return (recorded, recordedAt)
    }

    public var isTerminal: Bool { recorded != nil }
}
