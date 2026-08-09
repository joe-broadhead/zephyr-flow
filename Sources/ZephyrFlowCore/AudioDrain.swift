import Foundation

// JOE-2248: audio stop/drain barrier and frame-accounting invariants.
//
// Deterministic + AppKit-free: guarantees final transcription begins only
// after every accepted microphone frame reached the engine or was explicitly
// classified as dropped/degraded. Counts only — never audio payloads.

// MARK: - Controlled degradation reasons (content-free)

public enum AudioDegradeReason: String, Codable, CaseIterable, Sendable, Equatable {
    case overflow
    case wrongSession
    case closedDrop
    case gap
    case reorder
    case drainTimeout
    case converterFailure
    case lateAppend
    case reconciliationMismatch
}

// MARK: - Frame accounting

/// Per-session sample/frame totals (counts only). Reconciliation is the
/// success gate: successful sessions must satisfy the exact invariant, with
/// converter rounding defined separately and explicitly.
public struct AudioFrameAccounting: Sendable, Equatable {
    /// Source-rate samples accepted by the channel (captured).
    /// Source sample rate observed from the capture chunks (Hz). Chunks in
    /// one session share the hardware source rate; the converter resamples to
    /// the engine rate. Used for the conversion ratio (review R1.2).
    public private(set) var sourceSampleRate: Double = 16_000
    public private(set) var capturedSourceSamples: UInt64 = 0
    /// Engine-rate samples produced by the converter.
    public private(set) var convertedEngineSamples: UInt64 = 0
    /// Engine-rate samples appended to the engine (delivered).
    public private(set) var deliveredEngineSamples: UInt64 = 0
    /// Source-rate samples dropped (overflow / wrong-session / post-close /
    /// late-append).
    public private(set) var droppedSourceSamples: UInt64 = 0
    /// Engine partial frames observed (decoded) — optional signal.
    public private(set) var decodedEngineSamples: UInt64 = 0
    public private(set) var degradeReasons: Set<AudioDegradeReason> = []

    public init() {}

    public var isDegraded: Bool { !degradeReasons.isEmpty }

    public mutating func noteCaptured(sourceSamples: UInt64, sourceRate: Double) {
        if sourceRate > 0 { sourceSampleRate = sourceRate }
        capturedSourceSamples &+= sourceSamples
    }

    public mutating func noteConverted(engineSamples: UInt64) {
        convertedEngineSamples &+= engineSamples
    }

    public mutating func noteDelivered(engineSamples: UInt64) {
        deliveredEngineSamples &+= engineSamples
    }

    public mutating func noteDropped(sourceSamples: UInt64, reason: AudioDegradeReason) {
        droppedSourceSamples &+= sourceSamples
        degradeReasons.insert(reason)
    }

    public mutating func noteDecoded(engineSamples: UInt64) {
        decodedEngineSamples &+= engineSamples
    }

    /// Reconciliation invariant for successful sessions:
    /// 1. Everything converted was delivered (engine-rate exact).
    /// 2. Converted ≈ (captured − dropped) × ratio within the explicitly
    ///    defined converter rounding tolerance.
    /// Any gap, overflow, drain timeout or mismatch => false (fail closed).
    public func reconciles(
        converterRatio: Double,
        roundingToleranceSamples: UInt64
    ) -> Bool {
        guard !isDegraded else { return false }
        guard deliveredEngineSamples == convertedEngineSamples else { return false }
        let expected = Double(capturedSourceSamples &- droppedSourceSamples) * converterRatio
        let actual = Double(convertedEngineSamples)
        let diff = UInt64(abs(expected - actual))
        return diff <= roundingToleranceSamples
    }
}

// MARK: - Drain barrier

public enum AudioDrainState: String, Codable, Sendable, Equatable {
    case idle
    case draining
    case drained
    case timedOut
    case cancelled
}

/// End-of-stream drain barrier (JOE-2248). After the capture tap stops, the
/// delivery task drains through the accepted final sequence; the barrier is
/// deadline-aware and cancellable. A late append after the final sequence is
/// counted (never silently cleared) and degrades the session.
public struct AudioDrainBarrier: Sendable, Equatable {
    public private(set) var state: AudioDrainState = .idle
    public let deadlineNanosAhead: UInt64
    public private(set) var finalSequence: UInt64?
    public private(set) var startedAtNanos: UInt64?
    public private(set) var lastDeliveredSequence: UInt64?
    public private(set) var lateAppends: UInt64 = 0

    public init(deadlineNanosAhead: UInt64 = 3_000_000_000) {
        self.deadlineNanosAhead = deadlineNanosAhead
    }

    public var isComplete: Bool { state == .drained }

    public mutating func begin(finalSequence: UInt64, nowNanos: UInt64) {
        guard state == .idle else { return }
        state = .draining
        self.finalSequence = finalSequence
        startedAtNanos = nowNanos
    }

    public func expired(nowNanos: UInt64) -> Bool {
        guard let started = startedAtNanos, state == .draining else { return false }
        return nowNanos &- started >= deadlineNanosAhead
    }

    /// One delivered chunk/sequence tick. Returns the barrier state.
    @discardableResult
    public mutating func noteDelivered(sequence: UInt64, nowNanos: UInt64) -> AudioDrainState {
        // A late append after the drain acknowledgment is counted even when
        // the barrier already drained — never silently cleared.
        if let final = finalSequence, sequence > final {
            lateAppends += 1
            return state
        }
        guard state == .draining else { return state }
        if expired(nowNanos: nowNanos) {
            state = .timedOut
            return state
        }
        lastDeliveredSequence = sequence
        if let final = finalSequence, sequence >= final {
            state = .drained
        }
        return state
    }

    public mutating func cancel() {
        guard state == .draining || state == .idle else { return }
        state = .cancelled
    }

    /// True once the barrier reached a terminal state (drained, timedOut,
    /// cancelled) — used to bound the consumer wait.
    public var isTerminal: Bool {
        state == .drained || state == .timedOut || state == .cancelled
    }

    public mutating func markTimedOut() {
        if state == .draining { state = .timedOut }
    }
}
