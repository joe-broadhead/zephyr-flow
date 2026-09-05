import Foundation

// JOE-2243: AppEnvironment — explicit dependency-injected subsystem boundaries.
//
// Composition root replacing process-global singleton coupling in session-
// domain code. Production implementations are assembled once at app launch;
// tests inject fakes without touching real UserDefaults, files, pasteboard,
// event taps, permissions, models or the wall clock. No production dependency
// performs work as a side effect of static initialization.

// MARK: - Cross-cutting protocols (deterministic)

/// Monotonic continuous clock (nanoseconds since boot).
public protocol ClockProviding: Sendable {
    func nowNanos() -> UInt64
}

/// Injectable sleeper (fakes record sleeps without real waiting).
public protocol Sleeper: Sendable {
    func sleep(nanoseconds: UInt64) async
}

/// Deterministic ID generation.
public protocol IDGenerating: Sendable {
    func next() -> UInt64
}

/// Content-free metrics event.
public enum MetricsEventKind: String, Codable, CaseIterable, Sendable, Equatable {
    case sessionStarted
    case sessionCompleted
    case sessionDegraded
    case sessionPartial
    case sessionTruncated
    case sessionCancelled
    case sessionFailed
    case sessionDeadlineExceeded
    case sessionSecureTarget
    case sessionAbandoned
    case targetValidated
    case targetChanged
    case targetGone
    case insertionVerified
    case insertionUnverified
    case insertionFailed
    case flowFallback
    case drainTimeout
    case engineError
}

public struct MetricsEvent: Sendable, Equatable {
    public let kind: MetricsEventKind
    public let value: UInt64
    public let atNanos: UInt64

    public init(kind: MetricsEventKind, value: UInt64, atNanos: UInt64) {
        self.kind = kind
        self.value = value
        self.atNanos = atNanos
    }
}

/// Metrics/event sink (counts only, no payloads).
public protocol MetricsSinking: Sendable {
    func record(_ event: MetricsEvent) async
}

/// Settings repository (production = SettingsStore; fakes = static).
public protocol SettingsRepository: Sendable {
    // Production settings are MainActor-owned. An async requirement permits
    // that isolation without exposing a synchronous nonisolated witness.
    var current: AppSettings { get async }
}

/// History repository (production = HistoryStore; fakes = in-memory).
public protocol HistoryRepository: Sendable {
    func prepareForSession(saveHistory: Bool) async -> Bool
    func add(_ entry: HistoryEntry) async
}

extension HistoryRepository {
    /// In-memory/test repositories need no encrypted disk initialization.
    public func prepareForSession(saveHistory: Bool) async -> Bool { !Task.isCancelled }
}

/// Permission/capability provider.
public protocol PermissionProviding: Sendable {
    var microphoneGranted: Bool { get async }
    var accessibilityTrusted: Bool { get async }
    var speechRecognitionGranted: Bool { get async }
}

/// Target validation service boundary (JOE-2268/2249).
public protocol TargetValidationProviding: Sendable {
    func captureSnapshot(sessionID: SessionID, nowNanos: UInt64) async -> TargetSnapshot?
    func currentContext(nowNanos: UInt64) async -> TargetValidationContext?
    func restoreToCapturedTarget(
        snapshot: TargetSnapshot,
        deadlineNanosAhead: UInt64
    ) async -> TargetRestoreMonitor
}

// MARK: - Deterministic fakes (tests)

public struct FakeClock: ClockProviding {
    public private(set) var now: UInt64
    public init(now: UInt64 = 0) { self.now = now }

    public mutating func advance(by nanos: UInt64) { now &+= nanos }
    public mutating func set(_ nanos: UInt64) { now = nanos }
    public func nowNanos() -> UInt64 { now }
}

public final class FakeSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [UInt64] = []
    public var sleeps: [UInt64] { lock.withLock { _sleeps } }
    public init() {}
    public func sleep(nanoseconds: UInt64) async {
        lock.withLock { _sleeps.append(nanoseconds) }
    }
}

public final class FakeIDGenerator: IDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var _counter: UInt64 = 1
    public init() {}
    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        defer { _counter &+= 1 }
        return _counter
    }
}

public actor RecordingMetricsSink: MetricsSinking {
    public private(set) var events: [MetricsEvent] = []
    public init() {}
    public func record(_ event: MetricsEvent) async { events.append(event) }
}

public struct StaticSettingsRepository: SettingsRepository {
    public let current: AppSettings
    public init(_ settings: AppSettings = .default) { self.current = settings }
}

public actor InMemoryHistoryRepository: HistoryRepository {
    public private(set) var entries: [HistoryEntry] = []
    public init() {}
    public func add(_ entry: HistoryEntry) async { entries.append(entry) }
}

public struct FakePermissionProvider: PermissionProviding {
    public let microphoneGranted: Bool
    public let accessibilityTrusted: Bool
    public let speechRecognitionGranted: Bool
    public init(microphone: Bool = true, accessibility: Bool = true, speech: Bool = true) {
        self.microphoneGranted = microphone
        self.accessibilityTrusted = accessibility
        self.speechRecognitionGranted = speech
    }
}

// MARK: - AppEnvironment composition root

public struct AppEnvironment: Sendable {
    // Cross-cutting.
    public let clock: any ClockProviding
    public let sleeper: any Sleeper
    public let idGenerator: any IDGenerating
    public let metrics: any MetricsSinking
    // Repositories.
    public let settings: any SettingsRepository
    public let history: any HistoryRepository
    public let permissions: any PermissionProviding
    // Subsystems.
    public let engines: EngineRegistry
    public let flow: any FlowProcessorProtocol
    public let insertion: any InsertionServiceProtocol
    public let targetValidation: any TargetValidationProviding

    public init(
        clock: any ClockProviding,
        sleeper: any Sleeper,
        idGenerator: any IDGenerating,
        metrics: any MetricsSinking,
        settings: any SettingsRepository,
        history: any HistoryRepository,
        permissions: any PermissionProviding,
        engines: EngineRegistry,
        flow: any FlowProcessorProtocol,
        insertion: any InsertionServiceProtocol,
        targetValidation: any TargetValidationProviding
    ) {
        self.clock = clock
        self.sleeper = sleeper
        self.idGenerator = idGenerator
        self.metrics = metrics
        self.settings = settings
        self.history = history
        self.permissions = permissions
        self.engines = engines
        self.flow = flow
        self.insertion = insertion
        self.targetValidation = targetValidation
    }

    /// Fully deterministic test environment (no real I/O or wall clock).
    public static func test(
        clock: FakeClock = FakeClock(),
        settings: AppSettings = .default,
        engine: (any WhisperEngineProtocol)? = nil,
        flow: any FlowProcessorProtocol = FlowProcessor.shared,
        history: (any HistoryRepository)? = nil,
        insertion: (any InsertionServiceProtocol)? = nil,
        target: (any TargetValidationProviding)? = nil
    ) -> AppEnvironment {
        AppEnvironment(
            clock: clock,
            sleeper: FakeSleeper(),
            idGenerator: FakeIDGenerator(),
            metrics: RecordingMetricsSink(),
            settings: StaticSettingsRepository(settings),
            history: history ?? InMemoryHistoryRepository(),
            permissions: FakePermissionProvider(),
            engines: EngineRegistry(
                whisper: engine ?? FakeWhisperEngine(),
                appleSpeech: nil),
            flow: flow,
            insertion: insertion ?? FakeInsertionService(),
            targetValidation: target ?? FakeTargetValidation())
    }
}

// MARK: - Engine registry

/// Factories for isolated engine candidates. Production factories must return
/// a fresh actor per load; reloading a session-owned actor is not permitted.
public struct EngineRegistry: Sendable {
    private let makeWhisper: (@Sendable () -> any WhisperEngineProtocol)?
    private let makeAppleSpeech: (@Sendable () -> any WhisperEngineProtocol)?

    /// Shared instances are useful for deterministic test fixtures only.
    public init(
        whisper: (any WhisperEngineProtocol)?,
        appleSpeech: (any WhisperEngineProtocol)?
    ) {
        if let whisper { makeWhisper = { whisper } } else { makeWhisper = nil }
        if let appleSpeech { makeAppleSpeech = { appleSpeech } } else { makeAppleSpeech = nil }
    }

    public init(
        makeWhisper: (@Sendable () -> any WhisperEngineProtocol)?,
        makeAppleSpeech: (@Sendable () -> any WhisperEngineProtocol)?
    ) {
        self.makeWhisper = makeWhisper
        self.makeAppleSpeech = makeAppleSpeech
    }

    public func makeEngine(for model: ModelIdentifier) -> (any WhisperEngineProtocol)? {
        model.isWhisperKit ? makeWhisper?() : makeAppleSpeech?()
    }
}

// MARK: - Fakes for engine/insertion/target (session pipeline construction)

/// Deterministic fake engine for pipeline tests.
public actor FakeWhisperEngine: WhisperEngineProtocol {
    public private(set) var isReady = true
    public var isQuarantined = false
    public private(set) var verifiedDigest: String?
    public func recordVerifiedDigest(_ digest: String?) { verifiedDigest = digest }
    public private(set) var modelName = "Fake"
    public private(set) var appended: [Float] = []
    public private(set) var streamStarts = 0
    private var partial: (@Sendable (PartialTranscription) -> Void)?
    public var finalText = "fake transcript"

    public init() {}

    public func load(model: ModelIdentifier, verifiedFolder: String? = nil) async throws {}
    public func startStreaming(
        sessionID: SessionID, localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        streamStarts += 1
        partial = onPartial
    }
    public func appendAudio(_ samples: [Float]) async { appended.append(contentsOf: samples) }
    public func stopAndFinalize() async throws -> EngineResult {
        EngineResult(
            text: finalText,
            completeness: .complete,
            frameAccounting: EngineFrameAccounting(
                capturedSourceSamples: 0,
                deliveredEngineSamples: 0,
                decodedEngineSamples: 0,
                droppedSourceSamples: 0),
            engine: EngineIdentity(
                kind: .whisper, modelName: modelName,
                modelVersion: nil, modelDigest: nil),
            languageRequested: nil, languageDetected: nil,
            confidence: 1.0, confidenceSource: "fake",
            startedAtUptimeNanos: 0, endedAtUptimeNanos: 1,
            inferenceDurationNanos: 1,
            warnings: [], fallbackReason: nil,
            termination: .completed)
    }
    public func cancel() async {}
    public func quarantine() async { isQuarantined = true }
}

/// Deterministic fake insertion service.
public actor FakeInsertionService: InsertionServiceProtocol {
    public private(set) var insertedText: String?
    public init() {}
    public func insert(_ text: String) async -> InsertionOutcome {
        insertedText = text
        return .verifiedInserted(
            strategy: .axSelectedText,
            evidence: .postWriteSelectionReRead, warnings: [])
    }
}

/// Deterministic fake target validation (no AX).
public struct FakeTargetValidation: TargetValidationProviding {
    public let snapshot: TargetSnapshot?
    public let context: TargetValidationContext?
    public init(
        snapshot: TargetSnapshot? = nil,
        context: TargetValidationContext? = nil
    ) {
        self.snapshot = snapshot
        self.context = context
    }
    public func captureSnapshot(sessionID: SessionID, nowNanos: UInt64) async -> TargetSnapshot? { snapshot }
    public func currentContext(nowNanos: UInt64) async -> TargetValidationContext? { context }
    public func restoreToCapturedTarget(
        snapshot: TargetSnapshot,
        deadlineNanosAhead: UInt64
    ) async -> TargetRestoreMonitor {
        var monitor = TargetRestoreMonitor(deadlineNanosAhead: deadlineNanosAhead)
        monitor.start(nowNanos: 0)
        return monitor
    }
}
