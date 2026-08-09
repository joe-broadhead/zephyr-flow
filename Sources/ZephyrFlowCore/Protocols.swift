import Foundation

// MARK: - WhisperEngine

public protocol WhisperEngineProtocol: Actor {
    var isReady: Bool { get }
    var modelName: String { get }
    /// Review R6: true when the engine instance is quarantined (a native
    /// decode was still busy at cleanup) and must be replaced before reuse.
    var isQuarantined: Bool { get }
    /// Review B8: the verified artifact digest recorded at load (from the
    /// reviewed manifest). Carried into EngineIdentity so session evidence
    /// records which verified artifact was loaded.
    var verifiedDigest: String? { get }
    /// Review B8: record the verified artifact digest for the loaded model.
    func recordVerifiedDigest(_ digest: String?)
    func load(model: ModelIdentifier) async throws
    /// - Parameter localOnly: When true, must not use any network path (fail closed).
    /// - Parameter sessionID: immutable session this stream belongs to
    ///   (JOE-2249/2250: session-scoped callbacks and decode ownership).
    func startStreaming(
        sessionID: SessionID,
        localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws
    func stopAndFinalize() async throws -> FinalTranscription
    func cancel() async
    func appendAudio(_ samples: [Float]) async
}

public enum WhisperEngineError: LocalizedError, Sendable {
    case notReady
    case alreadyStreaming
    case notStreaming
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    /// A native decode is still executing (single-flight, JOE-2250).
    case decodeBusy

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Speech engine is not ready"
        case .alreadyStreaming: return "Already listening"
        case .notStreaming: return "Not currently listening"
        case .modelLoadFailed(let m): return "Failed to load model: \(m)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        case .decodeBusy: return "Speech engine is still decoding"
        }
    }
}

// MARK: - Insertion

public protocol InsertionServiceProtocol: Actor {
    func insert(_ text: String) async -> InsertionOutcome

    /// Full-parameter insertion (session-scoped; JOE-2260/2269/2271).
    func insert(
        _ text: String,
        preferPaste: Bool,
        mode: InsertionMode,
        targetBundleID: String?,
        sensitivity: SessionSensitivity,
        sessionID: SessionID?,
        copyOnlyOverrides: Set<String>
    ) async -> InsertionOutcome
}

extension InsertionServiceProtocol {
    public func insert(
        _ text: String,
        preferPaste: Bool,
        mode: InsertionMode,
        targetBundleID: String?,
        sensitivity: SessionSensitivity,
        sessionID: SessionID?,
        copyOnlyOverrides: Set<String>
    ) async -> InsertionOutcome {
        await insert(text)
    }
}

// MARK: - Flow Processor

public protocol FlowProcessorProtocol: Actor {
    /// Typed outcome entry (JOE-2279): every style/backend path returns a
    /// complete outcome with loss class, changes, warnings and fallback.
    func process(_ request: FlowRequest) async -> FlowOutcome

    /// Legacy string entry (kept for compat; production orchestrates via
    /// the typed outcome API).
    func process(_ text: String, style: FlowStyle) async -> String
}

extension FlowProcessorProtocol {
    /// Language-aware legacy entry (JOE-2277). Default forwards with `.auto`.
    public func process(_ text: String, style: FlowStyle, language: SupportedLanguage) async -> String {
        await process(text, style: style)
    }

    /// Convenience: build a request with default context (tests/utilities).
    public func process(
        _ text: String, style: FlowStyle, language: SupportedLanguage,
        sensitivity: SessionSensitivity
    ) async -> FlowOutcome {
        await process(
            FlowRequest(
                sessionID: SessionID(
                    token: "flow", sequence: 0,
                    createdAtUptimeNanos: 0),
                text: text, style: style, language: language,
                sensitivity: sensitivity))
    }
}

// MARK: - Audio Capture

public protocol AudioCaptureProtocol: Actor {
    var isCapturing: Bool { get }
    func requestPermission() async -> Bool
    /// Start capture producing owned `AudioChunk`s into a bounded, ordered,
    /// session-bound channel (JOE-2247). The single consumer drains in exact
    /// producer order; overflow/cross-session chunks are surfaced, never
    /// silently dropped.
    func start(sessionID: SessionID, channel: BoundedAudioChannel) async throws
    func stop() async
    func levels() async -> [Float]
}

public enum AudioCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case engineStartFailed(String)
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission denied"
        case .engineStartFailed(let m): return "Audio engine failed: \(m)"
        case .noInputDevice: return "No microphone found"
        }
    }
}
