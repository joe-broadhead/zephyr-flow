import Foundation

/// AudioChunk (JOE-2247): one owned, contiguous PCM slice bound to an
/// immutable session. Samples are a private copy — never borrowed from an
/// AVAudioEngine tap buffer.
public struct AudioChunk: Sendable, Equatable {
    public let sessionID: SessionID
    /// Monotonic producer sequence; strictly increasing per session.
    public let sequence: UInt64
    /// Absolute sample offset since capture start, in SOURCE-RATE frames
    /// (the producer advances it by the source frame length; the converter
    /// resamples to the engine rate — this is NOT a 16 kHz reference).
    public let startSample: UInt64
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]

    public init(
        sessionID: SessionID,
        sequence: UInt64,
        startSample: UInt64,
        sampleRate: Double,
        channelCount: Int,
        samples: [Float]
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.startSample = startSample
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }

    public var isEmpty: Bool { samples.isEmpty }
}

/// Bounded, ordered, cross-session-isolated PCM channel (JOE-2247).
///
/// - Producer: the real-time audio tap calls `enqueue(_:)` — synchronous,
///   lock-guarded, one bounded copy. Never allocates unboundedly.
/// - Consumer: exactly one, `chunks` AsyncStream; conversion and engine
///   append happen there in producer order. Reordering is impossible by
///   construction.
/// - Overflow / wrong-session / post-close chunks are counted and surfaced
///   via `stats()`/`isDegraded`; nothing is dropped silently, and degraded
///   channels prevent ordinary success outcomes.
public final class BoundedAudioChannel: @unchecked Sendable {
    public let sessionID: SessionID
    public let capacity: Int

    private let lock = NSLock()
    private var isClosedFlag = false
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let stream: AsyncStream<AudioChunk>

    private(set) public var overflowDropped: UInt64 = 0
    private(set) public var wrongSessionRejected: UInt64 = 0
    private(set) public var closedDropped: UInt64 = 0
    private(set) public var enqueued: UInt64 = 0
    // JOE-2248: sample-level accounting (never payloads) + EOS marker.
    private(set) public var overflowDroppedSamples: UInt64 = 0
    private(set) public var wrongSessionDroppedSamples: UInt64 = 0
    private(set) public var closedDroppedSamples: UInt64 = 0
    private(set) public var acceptedSamples: UInt64 = 0
    private(set) public var lastAcceptedSequence: UInt64?

    public init(sessionID: SessionID, capacity: Int) {
        precondition(capacity > 0)
        self.sessionID = sessionID
        self.capacity = capacity
        var cont: AsyncStream<AudioChunk>.Continuation?
        // Bounded by `capacity`: the AsyncStream's internal buffer IS the
        // queue, and its capacity is released as the consumer dequeues.
        // `bufferingOldest` keeps the oldest chunks (start of the session)
        // and drops the newest when the consumer is too slow; the dropped
        // count is surfaced via the yield result (authoritative admission).
        self.stream = AsyncStream<AudioChunk>(
            bufferingPolicy: .bufferingOldest(capacity)
        ) { cont = $0 }
        self.continuation = cont
    }

    /// Producer entry: synchronous, safe on the audio callout. Copies the
    /// chunk into the bounded ring before returning.
    @discardableResult
    public func enqueue(_ chunk: AudioChunk) -> AudioEnqueueResult {
        lock.lock()
        defer { lock.unlock() }
        guard chunk.sessionID == sessionID else {
            wrongSessionRejected += 1
            wrongSessionDroppedSamples += UInt64(chunk.samples.count)
            return .wrongSessionRejected
        }
        guard !isClosedFlag else {
            closedDropped += 1
            closedDroppedSamples += UInt64(chunk.samples.count)
            return .closed
        }
        // Authoritative admission: the bounded AsyncStream's yield result.
        // When the consumer is slower than the producer and the buffer is
        // full, yield returns .dropped — capacity is released only by the
        // consumer's dequeue, so a full buffer here is a genuine overload.
        if let result = continuation?.yield(chunk) {
            switch result {
            case .enqueued:
                enqueued += 1
                acceptedSamples += UInt64(chunk.samples.count)
                lastAcceptedSequence = chunk.sequence
                return .accepted
            case .dropped, .terminated:
                overflowDropped += 1
                overflowDroppedSamples += UInt64(chunk.samples.count)
                return .overflowDropped
            @unknown default:
                overflowDropped += 1
                overflowDroppedSamples += UInt64(chunk.samples.count)
                return .overflowDropped
            }
        } else {
            // Stream already finished/never started: treat as dropped.
            overflowDropped += 1
            overflowDroppedSamples += UInt64(chunk.samples.count)
            return .overflowDropped
        }
    }

    /// Exactly-one consumer stream, ordered by producer sequence.
    public var chunks: AsyncStream<AudioChunk> { stream }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosedFlag else { return }
        isClosedFlag = true
        continuation?.finish()
    }

    public var isClosed: Bool { lock.withLock { isClosedFlag } }
    // Review NIT-1: the AsyncStream buffer is the queue; its live buffered
    // count is not directly queryable, so this reports the CUMULATIVE number
    // of chunks accepted since start (capacity is the bound; overflow is
    // authoritative via yield). Named honestly — NOT "occupancy".
    public var acceptedEnqueueCount: Int { lock.withLock { Int(enqueued) } }

    /// ANY overflow or cross-session rejection makes the capture degraded:
    /// callers must map this to a non-ordinary outcome.
    public var isDegraded: Bool {
        lock.withLock { overflowDropped > 0 || wrongSessionRejected > 0 }
    }

    public func stats() -> AudioChannelStats {
        lock.withLock {
            AudioChannelStats(
                capacity: capacity,
                enqueued: enqueued,
                overflowDropped: overflowDropped,
                wrongSessionRejected: wrongSessionRejected,
                closedDropped: closedDropped,
                acceptedSamples: acceptedSamples,
                overflowDroppedSamples: overflowDroppedSamples,
                wrongSessionDroppedSamples: wrongSessionDroppedSamples,
                closedDroppedSamples: closedDroppedSamples,
                lastAcceptedSequence: lastAcceptedSequence)
        }
    }
}

public enum AudioEnqueueResult: Sendable, Equatable {
    case accepted
    case overflowDropped
    case wrongSessionRejected
    case closed
}

public struct AudioChannelStats: Sendable, Equatable {
    public let capacity: Int
    public let enqueued: UInt64
    public let overflowDropped: UInt64
    public let wrongSessionRejected: UInt64
    public let closedDropped: UInt64
    // JOE-2248 sample-level counters (content-free).
    public let acceptedSamples: UInt64
    public let overflowDroppedSamples: UInt64
    public let wrongSessionDroppedSamples: UInt64
    public let closedDroppedSamples: UInt64
    public let lastAcceptedSequence: UInt64?

    public init(
        capacity: Int, enqueued: UInt64, overflowDropped: UInt64,
        wrongSessionRejected: UInt64, closedDropped: UInt64,
        acceptedSamples: UInt64, overflowDroppedSamples: UInt64,
        wrongSessionDroppedSamples: UInt64, closedDroppedSamples: UInt64,
        lastAcceptedSequence: UInt64?
    ) {
        self.capacity = capacity
        self.enqueued = enqueued
        self.overflowDropped = overflowDropped
        self.wrongSessionRejected = wrongSessionRejected
        self.closedDropped = closedDropped
        self.acceptedSamples = acceptedSamples
        self.overflowDroppedSamples = overflowDroppedSamples
        self.wrongSessionDroppedSamples = wrongSessionDroppedSamples
        self.closedDroppedSamples = closedDroppedSamples
        self.lastAcceptedSequence = lastAcceptedSequence
    }

    public var totalDropped: UInt64 { overflowDropped + wrongSessionRejected + closedDropped }
    public var totalDroppedSamples: UInt64 {
        overflowDroppedSamples + wrongSessionDroppedSamples + closedDroppedSamples
    }
}

/// One-shot sequential gate: keeps the consumer honest even if upstream ever
/// reorders (defense-in-depth). Expected sequence fast-forwards over gaps.
public struct AudioChunkSequencer: Sendable {
    public private(set) var nextExpected: UInt64 = 0
    public private(set) var gaps: UInt64 = 0
    public private(set) var reordered: UInt64 = 0

    public init() {}

    /// Returns true when the chunk is the exact next sequence.
    @discardableResult
    public mutating func accept(_ chunk: AudioChunk) -> Bool {
        guard chunk.sequence == nextExpected else {
            if chunk.sequence > nextExpected {
                gaps += UInt64(chunk.sequence - nextExpected)
                nextExpected = chunk.sequence &+ 1
            } else {
                reordered += 1
            }
            return false
        }
        nextExpected &+= 1
        return true
    }

    public var isDegraded: Bool { gaps > 0 || reordered > 0 }
}
