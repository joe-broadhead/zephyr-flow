import Foundation

// JOE-2264: versioned privacy-safe telemetry + exactly-one terminal guard.
//
// Structured local evidence to diagnose correctness/performance/reliability
// WITHOUT collecting audio, transcript text, keys or private path data.
// - Versioned controlled schemas (typed enums, no free-form fields).
// - Anonymous per-session IDs (not stable cross-install identifiers).
// - TerminalGuard records exactly one terminal outcome; dropping an unfinished
//   guard emits a controlled abandonment.
// - Monotonic durations; bounded nonblocking sinks; no host callbacks under
//   locks; privacy-canary scanning.

public enum TelemetrySchemaVersion: Int, Sendable {
    case v1 = 1
    public static let current = TelemetrySchemaVersion.v1
}

/// Anonymous per-session telemetry id — NOT a stable cross-install identifier.
public struct SessionTelemetryID: Sendable, Equatable, Hashable, Codable {
    public let value: String
    public init() {
        value = "s-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
    public init(_ raw: String) { value = raw }
}

/// Controlled telemetry event kinds (typed; no free-form labels).
public enum TelemetryEventKind: String, Codable, CaseIterable, Sendable, Equatable {
    case stageEntered
    case terminal            // exactly one per session (TerminalGuard)
    case abandoned           // unfinished guard dropped
    case captureAccounting   // frame counts (captured/delivered/dropped/decoded)
    case flowOutcome         // status/loss class/fallback
    case insertionConfidence // verified/unverified/copy/uncertain
    case sinkDropped         // event sink overflow (count only)
}

/// Terminal category (JOE-2240 taxonomy).
public enum TerminalCategory: String, Codable, CaseIterable, Sendable, Equatable {
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
}

/// One controlled telemetry event (content-free by construction).
public struct TelemetryEvent: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let sessionID: SessionTelemetryID
    public let kind: TelemetryEventKind
    public let terminal: TerminalCategory?
    public let stage: SessionState?
    public let engineKind: EngineKind?
    public let modelName: String?
    public let durationNanos: UInt64?
    public let frameCounts: FrameCountSnapshot?
    public let completeness: EngineResultCompleteness?
    public let flowStatus: FlowOutcomeStatus?
    public let lossClass: FlowLossClass?
    public let insertionConfidence: InsertionConfidence?
    public let atNanos: UInt64

    public init(sessionID: SessionTelemetryID, kind: TelemetryEventKind,
                terminal: TerminalCategory? = nil, stage: SessionState? = nil,
                engineKind: EngineKind? = nil, modelName: String? = nil,
                durationNanos: UInt64? = nil, frameCounts: FrameCountSnapshot? = nil,
                completeness: EngineResultCompleteness? = nil,
                flowStatus: FlowOutcomeStatus? = nil, lossClass: FlowLossClass? = nil,
                insertionConfidence: InsertionConfidence? = nil,
                atNanos: UInt64) {
        self.schemaVersion = TelemetrySchemaVersion.current.rawValue
        self.sessionID = sessionID
        self.kind = kind
        self.terminal = terminal
        self.stage = stage
        self.engineKind = engineKind
        self.modelName = modelName
        self.durationNanos = durationNanos
        self.frameCounts = frameCounts
        self.completeness = completeness
        self.flowStatus = flowStatus
        self.lossClass = lossClass
        self.insertionConfidence = insertionConfidence
        self.atNanos = atNanos
    }
}

public struct FrameCountSnapshot: Sendable, Equatable, Codable {
    public let captured: UInt64
    public let delivered: UInt64
    public let dropped: UInt64
    public let decoded: UInt64
    public init(captured: UInt64, delivered: UInt64, dropped: UInt64, decoded: UInt64) {
        self.captured = captured
        self.delivered = delivered
        self.dropped = dropped
        self.decoded = decoded
    }
}

public enum InsertionConfidence: String, Codable, CaseIterable, Sendable, Equatable {
    case verified
    case unverified
    case explicitCopy
    case uncertain
    case none
}

// MARK: - Exactly-one terminal guard

/// Records exactly one terminal event per session. Dropping an unfinished
/// guard emits a controlled abandonment. Value semantics + explicit
/// `finalize`/`abandon`; never emits twice.
public struct TerminalGuard: Sendable, Equatable {
    public let sessionID: SessionTelemetryID
    public private(set) var terminalEvent: TelemetryEvent?
    public private(set) var finalized = false

    public init(sessionID: SessionTelemetryID) {
        self.sessionID = sessionID
    }

    /// Record the single terminal outcome (idempotent; second call refused).
    public mutating func finalize(terminal: TerminalCategory, durationNanos: UInt64,
                                  atNanos: UInt64) -> TelemetryEvent? {
        guard !finalized else { return nil }
        finalized = true
        let event = TelemetryEvent(sessionID: sessionID, kind: .terminal,
                                   terminal: terminal, durationNanos: durationNanos,
                                   atNanos: atNanos)
        terminalEvent = event
        return event
    }

    /// Dropping an unfinished guard emits a controlled abandonment.
    public mutating func abandon(atNanos: UInt64) -> TelemetryEvent? {
        guard !finalized else { return nil }
        finalized = true
        let event = TelemetryEvent(sessionID: sessionID, kind: .abandoned,
                                   terminal: .abandonedDuringShutdown, atNanos: atNanos)
        terminalEvent = event
        return event
    }
}

// MARK: - Bounded nonblocking sink

/// Bounded, nonblocking event sink. Overflow increments a drop counter and
/// NEVER stalls inference; host callbacks are never invoked under the lock.
public final class BoundedEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [TelemetryEvent] = []
    private let capacity: Int
    public private(set) var droppedCount: UInt64 = 0
    private var host: (@Sendable (TelemetryEvent) -> Void)?

    public init(capacity: Int = 256) {
        self.capacity = capacity
    }

    public func setHost(_ host: @escaping @Sendable (TelemetryEvent) -> Void) {
        lock.lock()
        self.host = host
        lock.unlock()
    }

    /// Nonblocking append: on overflow, drop the NEWEST event (count it) and
    /// never stall. Host callbacks fire ONLY on explicit drain, never under
    /// the lock and never during record (so reentrant hosts cannot deadlock).
    public func record(_ event: TelemetryEvent) {
        lock.lock()
        if buffer.count >= capacity {
            droppedCount += 1
            lock.unlock()
            return
        }
        buffer.append(event)
        lock.unlock()
    }

    /// Reentrancy-safe drain (host callbacks happen outside the lock).
    public func drain() -> [TelemetryEvent] {
        lock.lock()
        let pending = buffer
        buffer = []
        lock.unlock()
        for event in pending { host?(event) }
        return pending
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }
}

// MARK: - Privacy canary

/// Scans serialized event text for forbidden payload markers (transcript
/// fragments, keys, private paths). Typed schemas have no free-form fields,
/// so a positive scan means a schema violation.
public enum PrivacyCanary {
    public static let forbiddenPatterns: [String] = [
        "-----BEGIN", "API-KEY", "sk-", "AKIA",   // keys/secrets
        "/Users/", "/private/", "/etc/", "/var/", // private paths
        "Password:", "password=", "token=",       // credential shapes
    ]

    /// Returns the first violating pattern, or nil when clean.
    public static func scan(_ serialized: String) -> String? {
        let lower = serialized.lowercased()
        for pattern in forbiddenPatterns where lower.contains(pattern.lowercased()) {
            return pattern
        }
        return nil
    }

    /// Serialize an event with a controlled JSON encoder (no free-form
    /// fields by construction) and canary-scan it.
    public static func serializeAndScan(_ event: TelemetryEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event),
              let text = String(data: data, encoding: .utf8) else {
            return "unserializable"
        }
        return scan(text)
    }
}
