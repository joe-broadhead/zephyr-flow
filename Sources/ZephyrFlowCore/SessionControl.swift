import Foundation

/// Deterministic session control model (JOE-2246).
///
/// The app must not treat press/release/cancel as stage work: control events
/// act on the session immediately. This value type owns the only legal
/// control transitions (via `SessionStateMachine`), the immutable
/// `SessionID`, admission, idempotent duplicate handling and exactly-one
/// terminal outcome — without AppKit or async machinery, so it is fully
/// deterministic-testable (fake clock).
public struct SessionControlModel: Sendable, Equatable {
    /// Immutable identity of the current session; nil only between sessions.
    public private(set) var sessionID: SessionID?
    public private(set) var state: SessionState = .idle
    /// Whether new sessions may be admitted (shutdown closes this).
    public private(set) var admissionOpen = true
    public private(set) var terminal: StageOutcomeCategory?
    /// Monotonic generation: late callbacks carry the session id and are
    /// rejected when it differs from the current one.
    public private(set) var generation: UInt64 = 0
    /// Monotonic session counter for deterministic id tokens.
    private var nextSequence: UInt64 = 0

    public init() {}

    public var idPrefix: String = "zf"

    // MARK: - Deterministic id source

    private mutating func makeSessionID(createdAtNanos: UInt64) -> SessionID {
        nextSequence += 1
        return SessionID(token: idPrefix, sequence: nextSequence, createdAtUptimeNanos: createdAtNanos)
    }

    // MARK: - Control events (hotkey/app path)

    /// Begin a new session; allocate the immutable SessionID BEFORE any async
    /// work. Idempotent: a second begin while a session is active is a no-op
    /// (duplicate press / toggle edge).
    @discardableResult
    public mutating func begin(nowNanos: UInt64 = 0) -> SessionID? {
        guard admissionOpen else { return nil }
        if state != .idle && !state.isTerminal { return nil }
        sessionID = nil
        terminal = nil
        state = .idle
        generation &+= 1
        let sid = makeSessionID(createdAtNanos: nowNanos)
        sessionID = sid
        _ = apply(.begin, sid: sid)
        return sid
    }

    /// Admit a pre-allocated (factory-unique) SessionID — JOE-2244: the
    /// per-session actor admits identity from a SHARED monotonic source so
    /// two successive sessions can never collide.
    @discardableResult
    public mutating func begin(sessionID sid: SessionID) -> SessionID? {
        guard admissionOpen else { return nil }
        if state != .idle && !state.isTerminal { return nil }
        sessionID = nil
        terminal = nil
        state = .idle
        generation &+= 1
        sessionID = sid
        _ = apply(.begin, sid: sid)
        return sid
    }

    /// User release / toggle stop. Must act immediately even while the stage
    /// FIFO (model load / inference) is busy. In `capturing` this drives the
    /// drain barrier; in `preparing` it cancels so a release during a blocked
    /// model load prevents capture from ever starting. Later-stage releases
    /// are idempotent no-ops (pipeline already owned by the session).
    @discardableResult
    public mutating func stop(nowNanos: UInt64 = 0) -> SessionControlEffect {
        guard let sid = sessionID, !state.isTerminal else { return .noSessionOrTerminal }
        switch state {
        case .capturing:
            return apply(.stop, sid: sid)
        case .preparing:
            return apply(.cancel, sid: sid)
        case .draining, .transcribing, .transforming, .resolvingTarget, .inserting:
            return .idempotentNoop
        case .idle:
            return .idempotentNoop
        default:
            return .idempotentNoop
        }
    }

    /// Cancel anywhere; idempotent after terminal.
    @discardableResult
    public mutating func cancel(nowNanos: UInt64 = 0) -> SessionControlEffect {
        guard let sid = sessionID else { return .idempotentNoop }
        if state.isTerminal { return .idempotentNoop }
        return apply(.cancel, sid: sid)
    }

    /// Application termination: new sessions rejected, active session lands in
    /// `abandonedDuringShutdown`, admission closes.
    @discardableResult
    public mutating func shutdown(nowNanos: UInt64 = 0) -> SessionControlEffect {
        admissionOpen = false
        guard let sid = sessionID, !state.isTerminal else { return .idempotentNoop }
        return apply(.shutdownRequested, sid: sid)
    }

    // MARK: - Stage progress events (pipeline internals)

    public mutating func stage(_ event: SessionEvent) -> SessionStageResult {
        guard let sid = sessionID, !state.isTerminal else {
            return .rejected(reason: .noActiveSession)
        }
        let machine = SessionStateMachine()
        switch machine.transition(from: state, event: event) {
        case .to(let next):
            _ = applyTransition(next, sid: sid)
            return .accepted(newState: state)
        case .stay:
            return .idempotent
        case .illegal:
            return .rejected(reason: .illegalTransition(state: state, event: event))
        }
    }

    /// Drive the session to a terminal state for the given category
    /// (review R1.5). The state machine must accept the transition; if the
    /// current state cannot legally reach that terminal (e.g. a duplicate
    /// terminal or an illegal event for the current stage), it is an
    /// idempotent no-op: the state is left unchanged (no force-apply) and the
    /// returned SessionState reports exactly what the machine actually
    /// allowed. Callers MUST inspect the returned state and emit telemetry
    /// that matches it (the state machine is authoritative; see B3v2). This
    /// makes exactly-once terminal OUTCOME (not just cleanup) a property of
    /// the control model.
    @discardableResult
    public mutating func finish(category: StageOutcomeCategory) -> SessionState {
        guard let sid = sessionID else { return state }
        guard !state.isTerminal else { return state }
        // Review B3 (round 5): the state machine is AUTHORITATIVE — never
        // force-apply a terminal the machine declares illegal. The event is
        // chosen STAGE-DEPENDENTLY (canonicalEvent(for:from:)) so every
        // failure category has a legal event from the current state: a
        // degraded drain uses .drainFailed from .draining, a finalize failure
        // uses .transcriptionFailed from .transcribing, an incomplete engine
        // uses .enginePartial/.engineTruncated from .transforming, a
        // post-Flow target failure uses .targetResolutionFailed from
        // .resolvingTarget. If the resulting state is still nonterminal the
        // orchestration is out of sync and the caller must NOT claim the
        // terminal (finishTerminal enforces this).
        let machine = SessionStateMachine()
        let canonicalEvent: SessionEvent? = SessionControlModel.canonicalEvent(for: category, from: state)
        if let event = canonicalEvent {
            switch machine.transition(from: state, event: event) {
            case .to(let next):
                // Legal transition (lands on the category's canonical
                // terminal; the machine maps drainFailed -> .degraded etc.).
                _ = applyTransition(next, sid: sid)
                return state
            case .stay:
                return state
            case .illegal:
                // No legal path: leave state unchanged (no force-apply).
                return state
            }
        }
        // No canonical event: leave state unchanged (no force-apply).
        return state
    }

    /// Stage-dependent canonical event that drives the state machine toward
    /// a category from the CURRENT state (round-5 B3). Each failure category
    /// now has a legal event per stage, so finish() reaches a terminal that
    /// matches the requested category instead of remaining nonterminal.
    public static func canonicalEvent(
        for category: StageOutcomeCategory,
        from state: SessionState
    ) -> SessionEvent? {
        switch category {
        case .completed: return .insertionSucceeded
        case .cancelled: return .cancel
        case .deadlineExceeded: return .deadlineViolated
        case .targetChanged: return .targetChanged
        case .secureTarget: return .targetSecure
        case .abandonedDuringShutdown: return .shutdownRequested
        case .degraded:
            // Degraded is a drain-stage failure terminal.
            return state == .draining ? .drainFailed : nil
        case .partial:
            // Engine partial is a transform-stage terminal.
            return state == .transforming ? .enginePartial : nil
        case .truncated:
            // Engine truncated is a transform-stage terminal.
            return state == .transforming ? .engineTruncated : nil
        case .failed:
            // Stage-specific failure event (never a generic cross-stage one).
            switch state {
            case .preparing: return .preparationFailed
            case .capturing: return .captureFailed
            case .draining: return .drainFailed
            case .transcribing: return .transcriptionFailed
            case .transforming: return .transformationFailed
            case .resolvingTarget: return .targetResolutionFailed
            case .inserting: return .insertionFailed
            default: return nil
            }
        }
    }

    // MARK: - Internals

    private mutating func apply(_ event: SessionEvent, sid: SessionID) -> SessionControlEffect {
        let machine = SessionStateMachine()
        switch machine.transition(from: state, event: event) {
        case .to(let next):
            _ = applyTransition(next, sid: sid)
            return .transitioned(state)
        case .stay:
            return .idempotentNoop
        case .illegal:
            return state.isTerminal ? .idempotentNoop : .illegal
        }
    }

    @discardableResult
    private mutating func applyTransition(_ next: SessionState, sid: SessionID) -> SessionState {
        precondition(sid == sessionID)
        state = next
        if next.isTerminal {
            terminal = SessionControlModel.terminalOutcome(for: next)
            // A terminal outcome is recorded once; a later Fn press begins a
            // NEW session. Admission closes only on shutdown.
        }
        return state
    }

    /// Exactly-one terminal mapping: SessionState terminal -> StageOutcomeCategory.
    public static func terminalOutcome(for state: SessionState) -> StageOutcomeCategory? {
        switch state {
        case .completed: return .completed
        case .degraded: return .degraded
        case .partial: return .partial
        case .truncated: return .truncated
        case .cancelled: return .cancelled
        case .deadlineExceeded: return .deadlineExceeded
        case .targetChanged: return .targetChanged
        case .secureTarget: return .secureTarget
        case .failed: return .failed
        case .abandonedDuringShutdown: return .abandonedDuringShutdown
        default: return nil
        }
    }

    /// A callback carrying this session id may still mutate state only when it
    /// matches the current session and the session is not terminal.
    public func isCurrent(_ sid: SessionID) -> Bool {
        sessionID == sid && !state.isTerminal
    }
}

/// Effect of a control event on the coordinator.
public enum SessionControlEffect: Sendable, Equatable {
    case transitioned(SessionState)
    case idempotentNoop  // duplicate press/release/cancel: no side effects
    case illegal
    case noSessionOrTerminal
}

public enum SessionStageReason: Sendable, Equatable {
    case noActiveSession
    case illegalTransition(state: SessionState, event: SessionEvent)
}

public enum SessionStageResult: Sendable, Equatable {
    case accepted(newState: SessionState)
    case idempotent
    case rejected(reason: SessionStageReason)

    /// True when the transition was rejected (illegal). Orchestration must
    /// stop rather than continue on a rejected transition (review R1.5).
    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    /// True when the transition was accepted or idempotent.
    public var isAccepted: Bool { !isRejected }
}
