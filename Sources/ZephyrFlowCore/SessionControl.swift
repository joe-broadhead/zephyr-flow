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
    case idempotentNoop   // duplicate press/release/cancel: no side effects
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
}
