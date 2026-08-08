import Foundation

// JOE-2250: exclusive cancellable decode ownership for WhisperKit.
//
// Replaces the Boolean `decodeInFlight` + sleep-polling gate. One operation
// owns the native decode at a time; cancellation/deadline can NEVER clear
// ownership while native inference is still executing — a new decode starts
// only after the prior operation is known to have ended. Deterministic and
// AppKit-free so concurrency/race tests run in the CLT core suite.

/// Purpose of a decode operation (content-free).
public enum DecodePurpose: String, Codable, Sendable, Equatable {
    case partial
    case final
}

/// Typed outcome of a decode operation (controlled taxonomy).
public enum DecodeOperationOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case completed
    case cancelled
    case deadlineExceeded
    case degraded            // e.g. native error, ownership loss
}

/// Immutable identity of one decode operation.
public struct DecodeOperation: Sendable, Equatable {
    public let operationID: UInt64
    public let purpose: DecodePurpose
    public let sessionID: SessionID
    public let startedAtNanos: UInt64
    public let deadlineNanosAhead: UInt64

    public init(operationID: UInt64, purpose: DecodePurpose, sessionID: SessionID,
                startedAtNanos: UInt64, deadlineNanosAhead: UInt64) {
        self.operationID = operationID
        self.purpose = purpose
        self.sessionID = sessionID
        self.startedAtNanos = startedAtNanos
        self.deadlineNanosAhead = deadlineNanosAhead
    }

    public func expired(nowNanos: UInt64) -> Bool {
        nowNanos &- startedAtNanos >= deadlineNanosAhead
    }
}

/// Single-flight ownership gate. Invariants (enforced by tests):
/// - At most ONE running operation at any instant (maxObservedConcurrency).
/// - `finish` returns ownership only for the current owner.
/// - `cancel`/`timeout` mark the outcome but DO NOT release ownership — the
///   native call is still executing; a new decode starts only after `finish`.
/// - Outcomes are recorded exactly once per operation.
public struct DecodeOwnership: Sendable, Equatable {
    public private(set) var owner: DecodeOperation?
    public private(set) var outcomes: [DecodeOperationOutcome] = []
    public private(set) var nextOperationID: UInt64 = 1
    public private(set) var maxObservedConcurrency: Int = 0
    public private(set) var rejectedWhileBusy: UInt64 = 0

    public init() {}

    public var isBusy: Bool { owner != nil }
    public var currentPurpose: DecodePurpose? { owner?.purpose }

    /// Try to begin an operation. Returns nil when a decode is still running
    /// (exclusive) — the caller must never start a second native decode.
    public mutating func begin(purpose: DecodePurpose,
                               sessionID: SessionID,
                               nowNanos: UInt64,
                               deadlineNanosAhead: UInt64 = 3_000_000_000) -> DecodeOperation? {
        guard owner == nil else {
            rejectedWhileBusy += 1
            return nil
        }
        let op = DecodeOperation(operationID: nextOperationID,
                                 purpose: purpose,
                                 sessionID: sessionID,
                                 startedAtNanos: nowNanos,
                                 deadlineNanosAhead: deadlineNanosAhead)
        nextOperationID &+= 1
        owner = op
        maxObservedConcurrency = max(maxObservedConcurrency, 1)
        return op
    }

    /// The native call actually ended. Releases ownership ONLY for the
    /// current owner; records the outcome exactly once.
    public mutating func finish(_ operation: DecodeOperation,
                                outcome: DecodeOperationOutcome) -> Bool {
        guard owner == operation else { return false }
        owner = nil
        record(outcome)
        return true
    }

    /// User cancellation: marks the outcome but RETAINS ownership until the
    /// native call actually ends (finish). A new decode cannot start while
    /// the instance is still busy.
    public mutating func cancel(_ operation: DecodeOperation) -> Bool {
        guard owner == operation else { return false }
        record(.cancelled)
        return true
    }

    /// Deadline: records the typed outcome but retains ownership until
    /// finish — never clears the gate while native inference is running.
    public mutating func timeoutIfExpired(nowNanos: UInt64) -> DecodeOperationOutcome? {
        guard let op = owner, op.expired(nowNanos: nowNanos) else { return nil }
        if !outcomes.contains(.deadlineExceeded) {
            record(.deadlineExceeded)
        }
        return .deadlineExceeded
    }

    /// Whether the engine may be reused (only after the prior op ended).
    public var reusable: Bool { owner == nil }

    private mutating func record(_ outcome: DecodeOperationOutcome) {
        if !outcomes.contains(outcome) {
            outcomes.append(outcome)
        }
    }
}

/// Deterministic fake decode adapter for race/stress tests: controllable
/// completion/cancellation, records concurrency, never actually decodes.
public struct FakeDecode: Sendable {
    public private(set) var started = 0
    public private(set) var finished = 0
    public private(set) var maxConcurrent = 0
    private let lock = NSLock()
    private var running = 0

    public init() {}

    public mutating func start() {
        lock.lock(); defer { lock.unlock() }
        started += 1
        running += 1
        maxConcurrent = max(maxConcurrent, running)
    }

    public mutating func end() {
        lock.lock(); defer { lock.unlock() }
        running -= 1
        finished += 1
    }

    public var currentRunning: Int {
        lock.lock(); defer { lock.unlock() }
        return running
    }
}
