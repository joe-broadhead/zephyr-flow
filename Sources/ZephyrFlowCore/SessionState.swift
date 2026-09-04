import Foundation

/// Typed SessionID allocated before any asynchronous preparation begins
/// (ADR JOE-2242 / implementation JOE-2246). Immutable and unique per session.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Human-visible short identifier for logs/metrics (never transcript data).
    public let token: String
    /// Monotonic logical sequence retained for test determinism.
    public let sequence: UInt64
    /// Continuous-clock capture instant (diagnostics only).
    public let createdAtUptimeNanos: UInt64

    public init(token: String, sequence: UInt64, createdAtUptimeNanos: UInt64) {
        self.token = token
        self.sequence = sequence
        self.createdAtUptimeNanos = createdAtUptimeNanos
    }

    public var description: String { "Session(\(token)#\(sequence))" }
}

/// SessionState: the only legal lifecycle for a dictation session
/// (ADR JOE-2242). Terminal states are absorbing; exactly one terminal
/// outcome is emitted.
public enum SessionState: String, Codable, CaseIterable, Sendable, Equatable {
    case idle
    case preparing  // model load / engine preparation
    case capturing  // microphone tap + ordered audio channel
    case draining  // stop/drain barrier before final inference
    case transcribing  // engine decode
    case transforming  // Flow rules
    case resolvingTarget  // target validation before insertion
    case inserting  // pasteboard/AX mutation
    // terminal
    case completed
    case degraded
    case partial
    case truncated
    case cancelled
    case deadlineExceeded
    case targetChanged
    case secureTarget
    case failed
    case abandonedDuringShutdown

    public var isTerminal: Bool {
        switch self {
        case .completed, .degraded, .partial, .truncated, .cancelled,
            .deadlineExceeded, .targetChanged, .secureTarget, .failed,
            .abandonedDuringShutdown:
            return true
        case .idle, .preparing, .capturing, .draining, .transcribing,
            .transforming, .resolvingTarget, .inserting:
            return false
        }
    }
}

/// Control-plane events; the state machine is driven ONLY through these
/// edges. Late/duplicate events from an older stage are rejected at the
/// service layer by SessionID/generation checks; `stay` idempotence covers
/// legal duplicate edges (e.g. a second press while capturing).
public enum SessionEvent: String, Codable, CaseIterable, Sendable, Equatable {
    case begin  // user press / start
    case cancel  // user cancel
    case shutdownRequested  // app termination
    case preparationFailed
    case readyToCapture  // preparation succeeded
    case captureFailed
    case stop  // user release; drain begins
    case drainFinished  // all accepted frames delivered
    /// Round-5 B3: the drain degraded (incomplete consumer, dropped frames,
    /// timeout) — a legal failure terminal from `.draining`.
    case drainFailed
    case transcriptionFailed
    case transcriptionFinished
    case transformationFailed
    case transformationFinished
    /// Round-5 B3: the engine produced a PARTIAL result (legal terminal from
    /// `.transforming`).
    case enginePartial
    /// Round-5 B3: the engine produced a TRUNCATED result (legal terminal
    /// from `.transforming`).
    case engineTruncated
    case targetValidationSucceeded
    case targetChanged
    case targetSecure
    case targetUnknown
    /// Round-5 B3: target resolution failed after Flow (legal terminal from
    /// `.resolvingTarget`).
    case targetResolutionFailed
    case insertionFailed
    case insertionSucceeded
    case deadlineViolated
}

/// A transition result. `stay` means the event is idempotently coalesced
/// (duplicate press/release); `.illegal` means the pair is forbidden.
public enum SessionTransition: Sendable, Equatable {
    case stay
    case to(SessionState)
    case illegal
}

/// SessionStateMachine: exhaustive, model-checked transition table
/// (ADR JOE-2242). The `transition(from:event:)` switch is exhaustive over
/// every (state, event) pair; adding a state or event is a compile error
/// until the matching row is extended. `SessionTransitionTable` mirrors the
/// same table for property/randomized tests.
public struct SessionStateMachine: Sendable {
    public init() {}

    public func transition(from state: SessionState, event: SessionEvent) -> SessionTransition {
        switch (state, event) {
        // ---- idle ----
        case (.idle, .begin):
            return .to(.preparing)
        case (.idle, .cancel), (.idle, .stop):
            return .stay
        case (.idle, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.idle, _):
            return .illegal

        // ---- preparing: cancellation must not queue behind model load ----
        case (.preparing, .cancel):
            return .to(.cancelled)
        case (.preparing, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.preparing, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.preparing, .readyToCapture):
            return .to(.capturing)
        case (.preparing, .preparationFailed):
            return .to(.failed)
        case (.preparing, _):
            return .illegal

        // ---- capturing ----
        case (.capturing, .stop):
            return .to(.draining)
        case (.capturing, .captureFailed):
            return .to(.failed)
        case (.capturing, .cancel):
            return .to(.cancelled)
        case (.capturing, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.capturing, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.capturing, .begin):
            return .stay
        case (.capturing, _):
            return .illegal

        // ---- draining ----
        case (.draining, .drainFinished):
            return .to(.transcribing)
        case (.draining, .drainFailed):
            // Round-5 B3: a degraded drain is a LEGAL failure terminal.
            return .to(.degraded)
        case (.draining, .cancel):
            return .to(.cancelled)
        case (.draining, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.draining, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.draining, _):
            return .illegal

        // ---- transcribing ----
        case (.transcribing, .transcriptionFinished):
            return .to(.transforming)
        case (.transcribing, .transcriptionFailed):
            return .to(.failed)
        case (.transcribing, .cancel):
            return .to(.cancelled)
        case (.transcribing, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.transcribing, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.transcribing, _):
            return .illegal

        // ---- transforming ----
        case (.transforming, .transformationFinished):
            return .to(.resolvingTarget)
        case (.transforming, .transformationFailed):
            return .to(.failed)
        case (.transforming, .enginePartial):
            // Round-5 B3: engine produced a partial result — legal terminal.
            return .to(.partial)
        case (.transforming, .engineTruncated):
            // Round-5 B3: engine produced a truncated result — legal terminal.
            return .to(.truncated)
        case (.transforming, .cancel):
            return .to(.cancelled)
        case (.transforming, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.transforming, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.transforming, _):
            return .illegal

        // ---- resolvingTarget ----
        case (.resolvingTarget, .targetValidationSucceeded):
            return .to(.inserting)
        case (.resolvingTarget, .targetChanged):
            return .to(.targetChanged)
        case (.resolvingTarget, .targetSecure):
            return .to(.secureTarget)
        case (.resolvingTarget, .targetUnknown):
            // Unknown sensitivity fails closed into the secure-terminal band.
            return .to(.secureTarget)
        case (.resolvingTarget, .targetResolutionFailed):
            // Round-5 B3: target resolution failed after Flow — legal terminal.
            return .to(.failed)
        case (.resolvingTarget, .cancel):
            return .to(.cancelled)
        case (.resolvingTarget, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.resolvingTarget, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.resolvingTarget, _):
            return .illegal

        // ---- inserting ----
        case (.inserting, .insertionSucceeded):
            return .to(.completed)
        case (.inserting, .insertionFailed):
            return .to(.failed)
        case (.inserting, .cancel):
            return .to(.cancelled)
        case (.inserting, .shutdownRequested):
            return .to(.abandonedDuringShutdown)
        case (.inserting, .deadlineViolated):
            return .to(.deadlineExceeded)
        case (.inserting, _):
            return .illegal

        // ---- terminal states are absorbing (enumerated for exhaustiveness) ----
        case (.completed, _), (.degraded, _), (.partial, _), (.truncated, _),
            (.cancelled, _), (.deadlineExceeded, _), (.targetChanged, _),
            (.secureTarget, _), (.failed, _), (.abandonedDuringShutdown, _):
            return .illegal
        }
    }
}
