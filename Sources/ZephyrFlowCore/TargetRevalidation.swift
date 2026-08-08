import Foundation

// JOE-2268: deterministic target revalidation model.
// The app layer supplies content-free observations (TargetValidationContext);
// every comparison, deadline and outcome decision lives here so the full
// outcome matrix (`validated`, `targetChanged`, `targetGone`, `targetUnknown`,
// `secureTarget`, `notEditable`, `deadlineExceeded`) is unit-testable with
// target-switch / app-lifecycle fakes. `TargetRestoreMonitor` replaces blind
// sleeps with a bounded, observable poll loop.

/// Strictness ordinal used for "most restrictive sensitivity wins".
extension SessionSensitivity {
    /// normal=0 < secure=1 < unknown=2. Unknown is the most restrictive
    /// (fail-closed) because no evidence exists to permit side effects.
    public var strictness: Int {
        switch self {
        case .normal: return 0
        case .secure: return 1
        case .unknown: return 2
        }
    }

    public static func mostRestrictive(_ a: SessionSensitivity, _ b: SessionSensitivity) -> SessionSensitivity {
        a.strictness >= b.strictness ? a : b
    }
}

/// Controlled outcome of pre-insertion target validation (JOE-2268).
public enum TargetValidationOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case validated
    case targetChanged
    case targetGone
    case targetUnknown
    case secureTarget
    case notEditable
    case deadlineExceeded
}

/// Content-free reason emitted alongside an outcome (used for logs/audit only;
/// never contains field text or document titles).
public enum TargetValidationReason: String, Codable, Sendable, Equatable {
    case matched
    case processGone
    case pidReused
    case bundleChanged
    case windowReplaced
    case elementReplaced
    case focusSwitched
    case notSettable
    case noAxEvidence
    case secureReclassified
    case deadlineExceeded
}

/// Current (re-resolved, immediately before insertion) observation of the
/// focused target. All fields are positional/identity metadata — never field
/// contents, titles, or selected text.
public struct TargetValidationContext: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let processStartUptimeNanos: UInt64?
    public let windowID: UInt32?
    public let element: TargetSnapshot.ElementIdentity?
    public let settable: Bool
    public let editable: Bool
    public let enabled: Bool
    public let sensitivity: SensitivityAssessment
    /// Continuous-clock instant of this observation.
    public let nowNanos: UInt64

    public init(
        pid: Int32,
        bundleID: String?,
        processStartUptimeNanos: UInt64?,
        windowID: UInt32?,
        element: TargetSnapshot.ElementIdentity?,
        settable: Bool,
        editable: Bool,
        enabled: Bool,
        sensitivity: SensitivityAssessment,
        nowNanos: UInt64
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.processStartUptimeNanos = processStartUptimeNanos
        self.windowID = windowID
        self.element = element
        self.settable = settable
        self.editable = editable
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.nowNanos = nowNanos
    }

    /// The empty (no AX evidence) context used when the re-resolution fails.
    public static func noAxEvidence(nowNanos: UInt64) -> TargetValidationContext {
        TargetValidationContext(
            pid: -1, bundleID: nil, processStartUptimeNanos: nil,
            windowID: nil, element: nil, settable: false,
            editable: false, enabled: false,
            sensitivity: SensitivityAssessment.unknown,
            nowNanos: nowNanos)
    }
}

/// Bounded, observable restore monitor. Replaces the legacy blind sleep:
/// the caller polls `poll(isFrontmost:nowNanos:)` until it returns
/// `.restored`, `.rejected` (attempt cap) or `.deadlineExceeded`.
public struct TargetRestoreMonitor: Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case pending
        case restoring
        case restored
        case rejected
    }

    public enum PollResult: Sendable, Equatable {
        /// keep waiting; attempt number and remaining budget
        case polling(attempt: Int, remainingNanos: UInt64)
        case restored(attempt: Int)
        case rejected(attempt: Int)
        case deadlineExceeded(elapsedNanos: UInt64)
    }

    public private(set) var status: Status
    public let deadlineNanosAhead: UInt64
    public let maxAttempts: Int
    public private(set) var startedAtNanos: UInt64?
    public private(set) var attempts: Int

    public init(deadlineNanosAhead: UInt64, maxAttempts: Int = 12) {
        self.status = .pending
        self.deadlineNanosAhead = deadlineNanosAhead
        self.maxAttempts = maxAttempts
        self.startedAtNanos = nil
        self.attempts = 0
    }

    public mutating func start(nowNanos: UInt64) {
        guard status == .pending else { return }
        status = .restoring
        startedAtNanos = nowNanos
    }

    /// One poll tick: the monitor stays fully deterministic — it can never
    /// block a session beyond the bounded deadline.
    public mutating func poll(isFrontmost: Bool, nowNanos: UInt64) -> PollResult {
        switch status {
        case .pending:
            start(nowNanos: nowNanos)
        case .restored:
            return .restored(attempt: attempts)
        case .rejected:
            return .rejected(attempt: attempts)
        case .restoring:
            break
        }

        attempts += 1
        if let started = startedAtNanos {
            let elapsed = nowNanos &- started
            if elapsed >= deadlineNanosAhead {
                status = .rejected
                return .deadlineExceeded(elapsedNanos: elapsed)
            }
            if isFrontmost {
                status = .restored
                return .restored(attempt: attempts)
            }
            if attempts >= maxAttempts {
                status = .rejected
                return .rejected(attempt: attempts)
            }
            return .polling(attempt: attempts, remainingNanos: deadlineNanosAhead &- elapsed)
        }
        return .polling(attempt: attempts, remainingNanos: deadlineNanosAhead)
    }
}

/// One-shot target validation with a bounded deadline. Mirrors the
/// SessionControlModel discipline (JOE-2246): outcome is decided exactly once,
/// terminal outcomes are absorbing, and expiry can never stall a session.
public struct TargetValidationSession: Sendable, Equatable {
    public let sessionID: SessionID
    public let snapshot: TargetSnapshot
    public let deadlineNanosAhead: UInt64
    public private(set) var startedAtNanos: UInt64?
    public private(set) var outcome: TargetValidationOutcome?
    public private(set) var reason: TargetValidationReason?
    /// Effective (most restrictive) sensitivity resolved at validation time.
    public private(set) var effectiveSensitivity: SessionSensitivity

    public init(sessionID: SessionID, snapshot: TargetSnapshot, deadlineNanosAhead: UInt64) {
        self.sessionID = sessionID
        self.snapshot = snapshot
        self.deadlineNanosAhead = deadlineNanosAhead
        self.startedAtNanos = nil
        self.outcome = nil
        self.reason = nil
        self.effectiveSensitivity = snapshot.sensitivity.sensitivity
    }

    public var isValidated: Bool { outcome == .validated }
    public var isTerminal: Bool { outcome != nil }

    public mutating func start(nowNanos: UInt64) {
        if startedAtNanos == nil { startedAtNanos = nowNanos }
    }

    /// Decide the validation outcome exactly once (idempotent afterwards).
    /// `context` is whatever the resolver could observe; `nil`/no-evidence
    /// yields `.targetUnknown` (fail-closed, no automatic side effect).
    public mutating func validate(context: TargetValidationContext?, nowNanos: UInt64) -> TargetValidationOutcome {
        if let outcome = outcome { return outcome }

        if let started = startedAtNanos, nowNanos &- started >= deadlineNanosAhead {
            outcome = .deadlineExceeded
            reason = .deadlineExceeded
            return outcome!
        }

        guard let context else {
            outcome = .targetUnknown
            reason = .noAxEvidence
            return outcome!
        }

        // Sensitivity recheck: most restrictive of captured vs current.
        let captured = snapshot.sensitivity.sensitivity
        let current = context.sensitivity.sensitivity
        let effective = SessionSensitivity.mostRestrictive(captured, current)
        effectiveSensitivity = effective
        if effective != .normal {
            outcome = .secureTarget
            reason = .secureReclassified
            return outcome!
        }

        // Process identity.
        if context.pid != snapshot.target.pid {
            // PID reuse detection: process start identity changed.
            if let snapshotStart = snapshot.target.processStartUptimeNanos,
                let currentStart = context.processStartUptimeNanos,
                snapshotStart != currentStart
            {
                outcome = .targetGone
                reason = .pidReused
            } else if let snapshotBundle = snapshot.target.bundleID,
                let currentBundle = context.bundleID,
                snapshotBundle != currentBundle
            {
                outcome = .targetChanged
                reason = .bundleChanged
            } else {
                outcome = .targetGone
                reason = .processGone
            }
            return outcome!
        }

        // PID reuse: same pid but different process start-time identity.
        if let snapshotStart = snapshot.target.processStartUptimeNanos,
            let currentStart = context.processStartUptimeNanos,
            snapshotStart != currentStart
        {
            outcome = .targetGone
            reason = .pidReused
            return outcome!
        }

        // Window identity.
        if let snapshotWindow = snapshot.target.windowID,
            let currentWindow = context.windowID,
            snapshotWindow != currentWindow
        {
            outcome = .targetChanged
            reason = .windowReplaced
            return outcome!
        }

        // Element identity (only when both sides expose it).
        if let snapshotElement = snapshot.element, let currentElement = context.element {
            if let snapToken = snapshotElement.resolutionToken,
                let currentToken = currentElement.resolutionToken,
                snapToken != currentToken
            {
                outcome = .targetChanged
                reason = .elementReplaced
                return outcome!
            }
            if snapshotElement.role != currentElement.role
                || snapshotElement.subrole != currentElement.subrole
            {
                outcome = .targetChanged
                reason = .focusSwitched
                return outcome!
            }
        } else if snapshot.element != nil && context.element == nil {
            // Lost element re-resolution; nothing settled enough to write to.
            outcome = .targetChanged
            reason = .focusSwitched
            return outcome!
        }

        // Capability gates: must still be writable & enabled.
        if !context.settable || !context.enabled || (snapshot.editable && !context.editable) {
            outcome = .notEditable
            reason = .notSettable
            return outcome!
        }

        outcome = .validated
        reason = .matched
        return outcome!
    }

    /// Whether the effective sensitivity was stricter than the captured one.
    public var upgradedBeforeInsertion: Bool {
        snapshot.sensitivity.sensitivity != effectiveSensitivity
    }
}
