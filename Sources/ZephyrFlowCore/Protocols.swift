import Foundation

// MARK: - WhisperEngine

public protocol WhisperEngineProtocol: Actor {
    var isReady: Bool { get }
    var modelName: String { get }
    func load(model: ModelIdentifier) async throws
    /// - Parameter localOnly: When true, must not use any network path (fail closed).
    func startStreaming(
        localOnly: Bool,
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

    public var errorDescription: String? {
        switch self {
        case .notReady: return "Speech engine is not ready"
        case .alreadyStreaming: return "Already listening"
        case .notStreaming: return "Not currently listening"
        case .modelLoadFailed(let m): return "Failed to load model: \(m)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        }
    }
}

// MARK: - Insertion

public protocol InsertionServiceProtocol: Actor {
    func insert(_ text: String) async -> InsertionOutcome
}

// MARK: - Flow Processor

public protocol FlowProcessorProtocol: Actor {
    func process(_ text: String, style: FlowStyle) async -> String
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
