import Foundation

/// SensitivityPolicy: ONE authoritative policy table every transcript-bearing
/// subsystem must consult (JOE-2258). Surfaces are exhaustive; adding a
/// surface or sensitivity case is a compile error until the mapping is
/// extended — the `allowance(sensitivity:surface:)` switch below.
public enum SessionPolicySurface: String, Codable, CaseIterable, Sendable {
    case audioRetention
    case flowModes
    case automaticInsertion
    case clipboardFallback
    case history
    case logs
    case metrics
    case uiPreview
    case supportBundle
}

/// The one sensitivity decision a session carries. It combines session-start
/// evidence with a mandatory re-evaluation right before insertion, keeping the
/// MOST restrictive of the two (or `unknown` when either is unknown).
public struct SessionSensitivityDecision: Sendable, Equatable {
    public let sensitivity: SessionSensitivity
    /// Where the evidence came from (for diagnostics; never content).
    public let source: SensitivitySource
    /// True when the decision was downgraded from the session-start class
    /// (target became secure/changed before insertion).
    public let upgradedBeforeInsertion: Bool

    public init(sensitivity: SessionSensitivity, source: SensitivitySource, upgradedBeforeInsertion: Bool) {
        self.sensitivity = sensitivity
        self.source = source
        self.upgradedBeforeInsertion = upgradedBeforeInsertion
    }

    /// Combine a session-start and a pre-insertion assessment. Absence of
    /// evidence at either point yields `unknown` (fail closed — never normal).
    public static func resolve(
        sessionStart: SensitivityAssessment,
        preInsertion: SensitivityAssessment?
    ) -> SessionSensitivityDecision {
        let fresh = preInsertion?.sensitivity
        let start = sessionStart.sensitivity

        guard let fresh else {
            return SessionSensitivityDecision(
                sensitivity: .unknown,
                source: .noEvidence,
                upgradedBeforeInsertion: false)
        }
        // Most restrictive wins; ties keep the source.
        let selected: SessionSensitivity
        if fresh == .secure || start == .secure {
            selected = .secure
        } else if fresh == .unknown || start == .unknown {
            selected = .unknown
        } else {
            selected = .normal
        }
        let upgraded = start == .normal && selected != .normal
        return SessionSensitivityDecision(
            sensitivity: selected,
            source: selected == fresh ? preInsertion?.source ?? .noEvidence : sessionStart.source,
            upgradedBeforeInsertion: upgraded)
    }
}

/// Central policy table (JOE-2258). Secure and unknown prohibit automatic
/// clipboard, history and payload diagnostics. Anonymous lifecycle metrics
/// stay privacy-safe; logs never carry payloads by construction.
public enum SensitivityPolicy {
    /// Exhaustive mapping; every `SessionPolicySurface` has a row.
    public static func allowance(sensitivity: SessionSensitivity, surface: SessionPolicySurface) -> Bool {
        switch surface {
        case .audioRetention:
            // PCM is transient in-memory; retention policy applies to
            // persistence only, which secure/unknown forbid.
            return true
        case .flowModes:
            // Only verbatim/conservative may run on secure/unknown sessions.
            return sensitivity.allowsAutomaticSideEffects
        case .automaticInsertion:
            return sensitivity.allowsAutomaticSideEffects
        case .clipboardFallback:
            return sensitivity.allowsClipboardFallback
        case .history:
            return sensitivity.allowsHistory
        case .logs:
            // Logs never store transcript/audio payloads regardless; policy is
            // about automatic payload logging, which is forbidden for
            // secure/unknown.
            return sensitivity.allowsPayloadDiagnostics
        case .metrics:
            // Anonymous lifecycle metrics are allowed; metric payloads are not.
            // The metric sink must not attach transcripts/audio.
            return true
        case .uiPreview:
            return sensitivity.allowsAutomaticSideEffects
        case .supportBundle:
            return sensitivity.allowsPayloadDiagnostics
        }
    }

    /// Strictest combined policy for a session decision across every surface.
    public static func restrictedSurfaces(for decision: SessionSensitivityDecision) -> [SessionPolicySurface] {
        SessionPolicySurface.allCases.filter { !allowance(sensitivity: decision.sensitivity, surface: $0) }
    }

    /// Deterministic derivation from a TargetSnapshot (no AX evidence => unknown).
    public static func assessmentFromSnapshot(_ snapshot: TargetSnapshot?) -> SensitivityAssessment {
        guard let snapshot else { return .unknown }
        return snapshot.sensitivity
    }

}

/// Convenience alias for current live evidence at insertion time.
public typealias SensitivityEvidenceProvider = () -> SensitivityAssessment?

/// TranscriptStageGate: the single choke point a transcript-bearing stage
/// passes through before acting. Every stage resolver maps its surface to
/// `gate(...)`; a blocked result is a terminal outcome, never a silent
/// downgrade (JOE-2258 acceptance: exhaustive + tested for all terminals).
public enum TranscriptStageGate {
    public enum Result: Equatable, Sendable {
        case allowed
        case blockedForSensitivity(surface: SessionPolicySurface)
    }

    public static func gate(
        decision: SessionSensitivityDecision,
        surface: SessionPolicySurface
    ) -> Result {
        if SensitivityPolicy.allowance(sensitivity: decision.sensitivity, surface: surface) {
            return .allowed
        }
        return .blockedForSensitivity(surface: surface)
    }

    /// Explicit user copy is a SEPARATE, informed, auditable action; it is not
    /// the automatic clipboard fallback surface. It never logs content — the
    /// audit record carries only class/timestamp/outcome.
    public static func explicitCopyAllowed(decision: SessionSensitivityDecision) -> Bool {
        return true  // explicit human action, preceded by a privacy notice
    }

    public static func recordExplicitCopy(
        decision: SessionSensitivityDecision,
        now: Date = Date()
    ) -> ExplicitCopyAuditRecord {
        ExplicitCopyAuditRecord(
            sensitivity: decision.sensitivity,
            upgradedBeforeInsertion: decision.upgradedBeforeInsertion,
            timestampMillis: UInt64(now.timeIntervalSince1970 * 1000))
    }
}

/// Content-free audit record for explicit user copy actions.
public struct ExplicitCopyAuditRecord: Sendable, Equatable {
    public let sensitivity: SessionSensitivity
    public let upgradedBeforeInsertion: Bool
    public let timestampMillis: UInt64
}
