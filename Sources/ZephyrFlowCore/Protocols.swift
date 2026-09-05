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
    /// - Parameter verifiedFolder: the promoted, verified artifact directory
    ///   (from the acquisition pipeline). When non-nil the engine MUST load
    ///   from that directory (Review B6v2: not WhisperKit's own cache) and
    ///   must not use the network.
    func load(model: ModelIdentifier, verifiedFolder: String?) async throws
    /// Check the session's language/privacy capabilities before readiness is
    /// published. No permission prompts, network activity or capture here.
    func preflight(localOnly: Bool, language: SupportedLanguage) async throws
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
    /// Review B1v2 (round 5): quarantine the engine — the delivery consumer
    /// could not be quiesced within the bounded deadline, so the engine may
    /// still be owned by an unfinished task. The instance must not be reused.
    func quarantine() async
}

extension WhisperEngineProtocol {
    public func preflight(localOnly: Bool, language: SupportedLanguage) async throws {
        // The default witness is isolated to the conforming engine actor.
        let ready = isReady
        let quarantined = isQuarantined
        guard ready && !quarantined else { throw WhisperEngineError.notReady }
    }
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
        copyOnlyOverrides: Set<String>,
        validatedElement: TargetSnapshot.ElementIdentity?,
        validatedPid: Int32?,
        validatedWindowID: UInt32?,
        lease: TargetLease?
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
        copyOnlyOverrides: Set<String>,
        validatedElement: TargetSnapshot.ElementIdentity? = nil,
        validatedPid: Int32? = nil,
        validatedWindowID: UInt32? = nil,
        lease: TargetLease? = nil
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

    /// Default typed entry for backends that only implement the legacy string
    /// API (e.g. a string-only test fixture). Wraps the output in a typed
    /// FlowOutcome using the same guardrail semantics as the deterministic
    /// backend so the protocol is satisfied in Swift 6 language mode.
    public func process(_ request: FlowRequest) async -> FlowOutcome {
        let started = Date()
        let output = await process(request.text, style: request.style, language: request.language)
        let duration = UInt64(Date().timeIntervalSince(started) * 1_000_000_000)
        let loss = FlowOutcome.lossClass(for: request.style)
        let inTokens = FlowGuardrails.tokens(in: request.text)
        let outTokens = FlowGuardrails.tokens(in: output)
        let covered = FlowGuardrails.inputCovered(input: inTokens, output: outTokens)
        let preserved = covered.ok
        let status: FlowOutcomeStatus = preserved ? .accepted : .rejected
        let warnings: [FlowWarning] = preserved ? [] : [.guardrailRejected]
        let fallbackReason: String? =
            preserved ? nil : "protected spans not preserved; original text returned (conservative)"
        let changed = (preserved && request.text != output) ? 1 : 0
        return FlowOutcome(
            text: preserved ? output : request.text,
            requestedStyle: request.style,
            resolvedLossClass: loss,
            backend: .regex,
            capabilityID: "io.zephyr-flow.flow.rules.v1",
            capabilityVersion: 1,
            language: request.language,
            changedRangeCount: changed,
            protectedSpanCount: inTokens.count,
            protectedSpansPreserved: preserved,
            status: status,
            warnings: warnings,
            fallbackReason: fallbackReason,
            durationNanos: duration,
            termination: .completed)
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
