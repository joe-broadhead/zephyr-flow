import Foundation

// JOE-2266: asynchronous application termination + recovery handshake.
//
// Deterministic, AppKit-free: quit/logout/restart/update must not abandon
// mutable resources, leave global preferences altered, or claim data was
// persisted when async cleanup never completed. The handshake is step-
// bounded, single-finalize, deadline-aware, and records a recovery marker
// when work could not quiesce.

public enum TerminationStep: String, Codable, CaseIterable, Sendable, Equatable {
    case admissionClosed      // close new-session/hotkey admission first
    case sessionFinished      // active session cancelled/finished per lifecycle
    case audioStopped         // tap stopped + drained
    case enginesQuiesced      // WhisperKit/Apple operations quiesced (bounded)
    case pasteboardResolved   // pasteboard restoration completed or abandoned
    case storageFlushed       // settings/history/metrics flushed, handles closed
    case preferencesRestored  // Fn/global preference restored exactly
}

public enum TerminationState: String, Codable, CaseIterable, Sendable, Equatable {
    case idle
    case running
    case completed
    case abandoned            // hard deadline hit; recovery marker recorded
}

public struct TerminationHandshake: Sendable, Equatable {
    public let deadlineNanosAhead: UInt64
    public private(set) var state: TerminationState = .idle
    public private(set) var startedAtNanos: UInt64?
    public private(set) var completedSteps: Set<TerminationStep> = []
    /// Exactly-once finalization guard (no double callbacks).
    public private(set) var finalizeCount: Int = 0
    /// Recovery marker written on the next launch when abandoned.
    public var recoveryMarker: String? {
        state == .abandoned ? "zephyr.incomplete-shutdown-\(abandonedReason ?? "unknown")" : nil
    }
    public private(set) var abandonedReason: String?

    public init(deadlineNanosAhead: UInt64 = 3_000_000_000) {
        self.deadlineNanosAhead = deadlineNanosAhead
    }

    public var isTerminal: Bool { state == .completed || state == .abandoned }

    public func expired(nowNanos: UInt64) -> Bool {
        guard let started = startedAtNanos else { return false }
        return nowNanos &- started >= deadlineNanosAhead
    }

    public mutating func begin(nowNanos: UInt64) {
        guard state == .idle else { return }
        state = .running
        startedAtNanos = nowNanos
    }

    /// Complete one step; hitting the deadline abandons the handshake with a
    /// recovery marker for the next launch.
    @discardableResult
    public mutating func completeStep(_ step: TerminationStep,
                                      nowNanos: UInt64) -> TerminationState {
        switch state {
        case .idle:
            begin(nowNanos: nowNanos)
        case .completed, .abandoned:
            return state
        case .running:
            break
        }
        if expired(nowNanos: nowNanos) {
            state = .abandoned
            abandonedReason = "deadline during \(step.rawValue)"
            return state
        }
        completedSteps.insert(step)
        if completedSteps.count == TerminationStep.allCases.count {
            state = .completed
        }
        return state
    }

    /// Exactly-once terminal callback guard (no double finalization).
    public mutating func markFinalized() -> Bool {
        guard finalizeCount == 0 else { return false }
        finalizeCount = 1
        return true
    }

    public var remainingSteps: [TerminationStep] {
        TerminationStep.allCases.filter { !completedSteps.contains($0) }
    }
}
