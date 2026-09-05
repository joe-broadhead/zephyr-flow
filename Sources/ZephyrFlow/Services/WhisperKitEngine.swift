import Accelerate
import Foundation
import WhisperKit
import ZephyrFlowCore

/// WhisperKit-backed engine. Model download consent is enforced separately
/// from the outstanding dependency tokenizer offline-load requirement.
///
/// Live partials use a **single-flight** rolling-window decode loop so we never
/// run concurrent `transcribe` calls (WhisperKit/NSProgress races → SIGSEGV).
actor WhisperKitEngine: WhisperEngineProtocol {
    private var _isReady = false
    /// Review B6: admission readiness is `_isReady && !isQuarantined`. A
    /// quarantined engine (native decode still busy at cleanup) must NOT be
    /// reused — the controller replaces it before the next session.
    public var isReady: Bool { _isReady && !_isQuarantined }
    private(set) var modelName = "WhisperKit"

    private var kit: (any WhisperTranscriptionRuntime)?
    private let runtimeFactory: WhisperRuntimeFactory
    private var pendingLoadToken: UUID?
    private var onPartial: (@Sendable (PartialTranscription) -> Void)?
    private var audioSamples: [Float] = []
    private var isStreaming = false
    private var isFinalizing = false
    /// JOE-2250: exclusive cancellable decode ownership (single-flight).
    private var decodeOwnership = DecodeOwnership()
    /// Review R3.2: set when a native decode was still busy at cleanup — the
    /// instance must not be reused for a new session (unsafe ownership).
    private var _isQuarantined = false
    public var isQuarantined: Bool { _isQuarantined }
    public private(set) var verifiedDigest: String?
    public func recordVerifiedDigest(_ digest: String?) {
        verifiedDigest = digest
    }
    private var currentDecodeSessionID: SessionID?
    /// Review R3.2: samples silently-dropped by the 60s rolling-window cap.
    private var droppedPrefixSamples: UInt64 = 0
    /// Review R3.2: true when the window cap was hit (visible degradation).
    private var didTruncateWindow = false
    private var startTime: Date?
    private var lastPartialText = ""
    private var partialLoopTask: Task<Void, Never>?

    private static let maxSampleCount = StreamingPartialWindow.sampleRate * 60

    init(
        runtimeFactory: @escaping WhisperRuntimeFactory = { try await WhisperKitRuntime.load($0) }
    ) {
        self.runtimeFactory = runtimeFactory
    }

    /// JOE-2254: decode options honor the session language snapshot. Fixed
    /// languages disable auto-detection (deterministic behavior); `auto`
    /// keeps engine detection.
    private func decodeOptions(language: SupportedLanguage) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.bcp47,
            temperature: 0.0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: language.isAuto,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 1.0,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1)
    }

    private func partialDecodeOptions(language: SupportedLanguage) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.bcp47,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: language.isAuto,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 1.0,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1)
    }

    private var currentLanguage: SupportedLanguage = .auto
    private var currentDecodeOptions: DecodingOptions?

    private static let minPartialRMS: Float = 0.0008

    func load(model: ModelIdentifier, verifiedFolder: String?) async throws {
        guard model.isWhisperKit else {
            throw WhisperEngineError.modelLoadFailed("Not a WhisperKit model: \(model.rawValue)")
        }

        // Round-5 B5: verified admission REQUIRES a verified folder. A nil
        // verifiedFolder must NEVER fall back to WhisperKit's own cache from
        // the verified path — that would load unverified bytes. Identifier/
        // cache loading is a separate explicitly-unverified developer API.
        guard let verifiedFolder else {
            throw WhisperEngineError.modelLoadFailed(
                "verified load refused — no verified artifact directory (identifier/cache fallback is not permitted from verified admission)"
            )
        }
        try await loadRuntime(
            WhisperRuntimeConfiguration(model: model, verifiedFolder: verifiedFolder, allowDownload: false))
    }

    func load(model: ModelIdentifier, allowDownload: Bool) async throws {
        guard model.isWhisperKit else {
            throw WhisperEngineError.modelLoadFailed("Not a WhisperKit model: \(model.rawValue)")
        }

        try await loadRuntime(
            WhisperRuntimeConfiguration(model: model, verifiedFolder: nil, allowDownload: allowDownload))
    }

    private func loadRuntime(_ configuration: WhisperRuntimeConfiguration) async throws {
        guard !isStreaming, !isFinalizing, !decodeOwnership.isBusy else {
            throw WhisperEngineError.decodeBusy
        }
        guard !_isQuarantined else { throw WhisperEngineError.notReady }
        let token = UUID()
        pendingLoadToken = token
        _isReady = false
        verifiedDigest = nil
        kit = nil
        ZFLog.info(
            "WhisperKit load model=\(configuration.model.rawValue) verified=\(configuration.verifiedFolder != nil)")
        do {
            let candidate = try await runtimeFactory(configuration)
            guard pendingLoadToken == token, !Task.isCancelled, !_isQuarantined else {
                throw CancellationError()
            }
            kit = candidate
            modelName =
                "WhisperKit (\(configuration.model.displayName))"
                + (configuration.verifiedFolder == nil ? "" : " [verified]")
            _isReady = true
            pendingLoadToken = nil
        } catch {
            if pendingLoadToken == token {
                pendingLoadToken = nil
                _isReady = false
            }
            if error is CancellationError { throw error }
            throw WhisperEngineError.modelLoadFailed(error.localizedDescription)
        }
    }

    func load(model: ModelIdentifier) async throws {
        try await load(model: model, allowDownload: false)
    }

    func startStreaming(
        sessionID: SessionID,
        localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        // Streaming uses only the already-loaded runtime. Offline tokenizer
        // initialization is a separate load-path requirement, not proven by
        // passing a folder or setting the model's download flag to false.
        _ = localOnly
        guard isReady, kit != nil else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        guard !_isQuarantined else {
            throw WhisperEngineError.notReady
        }
        currentDecodeSessionID = sessionID
        // Review R3.2: snapshot the requested language + decode options at
        // session start so the fixed-language contract is actually wired into
        // WhisperKit sessions (was never assigned).
        currentLanguage = language
        currentDecodeOptions = decodeOptions(language: language)
        droppedPrefixSamples = 0
        didTruncateWindow = false

        self.onPartial = onPartial
        audioSamples = []
        lastPartialText = ""
        isFinalizing = false
        decodeOwnership = DecodeOwnership()
        startTime = Date()
        isStreaming = true

        partialLoopTask?.cancel()
        partialLoopTask = Task { [weak self] in
            await self?.runPartialLoop()
        }
        ZFLog.info("Whisper streaming started (single-flight partials)")
    }

    func appendAudio(_ samples: [Float]) async {
        guard isStreaming, !isFinalizing else { return }
        audioSamples.append(contentsOf: samples)
        if audioSamples.count > Self.maxSampleCount {
            // Review R3.2: never silently discard audio. The rolling window is
            // bounded at ~60s, but the discarded prefix is COUNTED and the
            // session is marked truncated so the final result can never claim
            // a lossless `.complete` for a longer dictation.
            let dropped = UInt64(audioSamples.count - Self.maxSampleCount)
            audioSamples.removeFirst(audioSamples.count - Self.maxSampleCount)
            droppedPrefixSamples &+= dropped
            didTruncateWindow = true
            ZFLog.info("WhisperKit window capped at ~60s; dropped \(dropped) prefix samples (visible degradation)")
        }
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming else { throw WhisperEngineError.notStreaming }

        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil

        // MUST wait for any in-flight partial — never start a second concurrent transcribe.
        await waitForDecodeIdle()

        let duration = Date().timeIntervalSince(startTime ?? Date())
        let samples = audioSamples
        let rms = Self.rms(of: samples)
        let seconds = Double(samples.count) / Double(StreamingPartialWindow.sampleRate)
        ZFLog.info(
            "Whisper finalize samples=\(samples.count) (~\(String(format: "%.2f", seconds))s) rms=\(String(format: "%.5f", rms)) lastPartialLen=\(lastPartialText.count)"
        )

        guard samples.count >= 1_600 else {
            let fallback = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            let accounting = EngineFrameAccounting(
                capturedSourceSamples: UInt64(samples.count),
                deliveredEngineSamples: 0,
                decodedEngineSamples: 0,
                droppedSourceSamples: 0)
            cleanup()
            return EngineResult(
                text: fallback,
                completeness: .partial,
                frameAccounting: accounting,
                engine: engineIdentity(),
                languageRequested: nil, languageDetected: nil,
                confidence: nil, confidenceSource: nil,
                startedAtUptimeNanos: startTime?.timeIntervalSince1970 != nil
                    ? DispatchTime.now().uptimeNanoseconds : nil,
                endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
                inferenceDurationNanos: UInt64(duration * 1_000_000_000),
                warnings: [.shortAudioFallback],
                fallbackReason: "short-audio fallback",
                termination: .completed)
        }

        guard let kit else {
            cleanup()
            throw WhisperEngineError.notReady
        }

        let raw: String
        do {
            raw = try await runTranscribe(
                kit: kit, samples: samples, options: currentDecodeOptions ?? decodeOptions(language: currentLanguage),
                purpose: .final
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let fallback = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                ZFLog.info("Whisper finalize failed; using last partial len=\(fallback.count)")
                let accounting = EngineFrameAccounting(
                    capturedSourceSamples: UInt64(samples.count),
                    deliveredEngineSamples: 0,
                    decodedEngineSamples: 0,
                    droppedSourceSamples: 0)
                cleanup()
                // A final-decode failure with a rolling partial is NEVER
                // `complete` (JOE-2252): it is `partial` with a warning.
                return EngineResult(
                    text: fallback,
                    completeness: .partial,
                    frameAccounting: accounting,
                    engine: engineIdentity(),
                    languageRequested: nil, languageDetected: nil,
                    confidence: nil, confidenceSource: nil,
                    startedAtUptimeNanos: nil,
                    endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
                    inferenceDurationNanos: UInt64(duration * 1_000_000_000),
                    warnings: [.partialFallback],
                    fallbackReason: "final decode failed; rolling partial used",
                    termination: .failed)
            }
            cleanup()
            throw WhisperEngineError.transcriptionFailed(error.localizedDescription)
        }

        let finalText =
            raw.isEmpty
            ? lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            : raw
        // Frame evidence: captured == delivered (16 kHz reference), decoded
        // == delivered — required for a `complete` claim.
        let captured = UInt64(samples.count)
        let delivered = UInt64(samples.count)
        // Review R3.2: if the 60s window cap dropped a prefix, the result is
        // degraded-with-truncation, never a lossless `.complete`, and the
        // dropped samples are reflected in the frame accounting.
        let accounting = EngineFrameAccounting(
            capturedSourceSamples: captured,
            deliveredEngineSamples: delivered,
            decodedEngineSamples: delivered,
            droppedSourceSamples: droppedPrefixSamples)
        let truncated = didTruncateWindow
        let completeness = SpeechCompletenessPolicy.completenessWithTruncation(
            hasFinalText: !raw.isEmpty,
            didTruncateWindow: truncated)
        let warnings: [EngineWarning] = SpeechCompletenessPolicy.truncationWarnings(
            didTruncateWindow: truncated,
            baseWarnings: raw.isEmpty ? [.partialFallback] : [])
        cleanup()
        return EngineResult(
            text: finalText,
            completeness: completeness,
            frameAccounting: accounting,
            engine: engineIdentity(),
            languageRequested: currentLanguage.bcp47,
            languageDetected: currentLanguage.bcp47,
            confidence: nil, confidenceSource: nil,
            startedAtUptimeNanos: nil,
            endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
            inferenceDurationNanos: UInt64(duration * 1_000_000_000),
            warnings: warnings,
            fallbackReason: raw.isEmpty
                ? "no final decode; partial used"
                : (truncated ? "input window truncated at 60s" : nil),
            termination: .completed)
    }

    private func engineIdentity() -> EngineIdentity {
        EngineIdentity(
            kind: .whisper, modelName: modelName,
            modelVersion: nil, modelDigest: verifiedDigest)
    }

    func quarantine() async {
        _isQuarantined = true
        pendingLoadToken = nil
    }

    func cancel() async {
        // Invalidate publication before any suspension, even if the native
        // initializer ignores task cancellation and returns much later.
        pendingLoadToken = nil
        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        // Review R6: cancellation must be product-bounded — never wait the
        // full 120s decode-idle cap during app shutdown. Wait a SHORT bounded
        // window for a cooperative native decode to end; if it is still busy,
        // QUARANTINE immediately (cleanup() sets isQuarantined, and a fresh
        // engine replaces it before the next session). This keeps the 3s
        // termination handshake interruptible.
        let cancelWaitCap: UInt64 = 2_000_000_000  // 2s
        var waited: UInt64 = 0
        while decodeOwnership.isBusy, waited < cancelWaitCap {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10_000_000
        }
        cleanup()  // quarantines if decodeOwnership.isBusy
    }

    // MARK: - Single-flight decode

    /// JOE-2250: exclusive gate around every WhisperKit `transcribe` call.
    /// Finalization waits for the owned partial to END (finish) — it never
    /// starts a second decode after a polling cap, and a deadline retains
    /// ownership until the native call actually ends.
    private func runTranscribe(
        kit: any WhisperTranscriptionRuntime,
        samples: [Float],
        options: DecodingOptions,
        purpose: DecodePurpose
    ) async throws -> String {
        guard let sessionID = currentDecodeSessionID else {
            throw WhisperEngineError.notReady
        }
        // Wait for the prior native decode to actually end (single-flight).
        await waitForDecodeIdle()
        guard !Task.isCancelled else { throw CancellationError() }

        let now = DispatchTime.now().uptimeNanoseconds
        let op = decodeOwnership.begin(
            purpose: purpose,
            sessionID: sessionID,
            nowNanos: now)
        guard let op else {
            throw WhisperEngineError.decodeBusy
        }
        do {
            let text = try await kit.transcribe(samples: samples, options: options)
            _ = decodeOwnership.finish(op, outcome: .completed)
            return text
        } catch is CancellationError {
            _ = decodeOwnership.cancel(op)
            _ = decodeOwnership.finish(op, outcome: .cancelled)
            throw CancellationError()
        } catch {
            _ = decodeOwnership.finish(op, outcome: .degraded)
            throw error
        }
    }

    private func waitForDecodeIdle() async {
        // Ownership-based wait: reuse is allowed only after the prior native
        // operation actually ended. Deadline does NOT clear the gate.
        let step: UInt64 = 10_000_000
        let hardCap: UInt64 = 120_000_000_000
        var waited: UInt64 = 0
        while decodeOwnership.isBusy, waited < hardCap {
            // A timed-out owner is still executing natively; keep waiting.
            _ = decodeOwnership.timeoutIfExpired(
                nowNanos: DispatchTime.now().uptimeNanoseconds)
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        if decodeOwnership.isBusy {
            ZFLog.error("Whisper native decode still busy after \(waited / 1_000_000)ms")
            // Do NOT clear ownership: starting a second decode on a busy
            // instance would break single-flight. Surface as degraded below.
        }
    }

    // MARK: - Partials

    private func runPartialLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: StreamingPartialWindow.intervalNanoseconds)
            guard !Task.isCancelled else { break }
            guard isStreaming, !isFinalizing else { break }
            await emitPartialIfPossible()
        }
    }

    private func emitPartialIfPossible() async {
        guard isStreaming, !isFinalizing else { return }
        // Skip if a decode is already running (never queue a second concurrent one).
        guard !decodeOwnership.isBusy else { return }
        guard StreamingPartialWindow.canRunPartial(sampleCount: audioSamples.count) else { return }
        guard let kit else { return }

        let slice = StreamingPartialWindow.sliceForPartial(audioSamples)
        let energy = Self.rms(of: slice)
        guard energy >= Self.minPartialRMS else { return }

        do {
            let text = try await runTranscribe(
                kit: kit, samples: slice,
                options: partialDecodeOptions(language: currentLanguage),
                purpose: .partial
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard isStreaming, !isFinalizing else { return }
            guard !text.isEmpty, text != lastPartialText else { return }
            lastPartialText = text
            ZFLog.debug("Whisper partial len=\(text.count)")
            onPartial?(PartialTranscription(text: text, isFinal: false))
        } catch {
            if !Task.isCancelled, isStreaming, !isFinalizing {
                ZFLog.debug("Whisper partial decode skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    private func cleanup() {
        partialLoopTask?.cancel()
        partialLoopTask = nil
        audioSamples = []
        onPartial = nil
        isStreaming = false
        isFinalizing = false
        // Review R3.2: never reset decode ownership while a native decode may
        // still be executing (e.g. a stuck call past the wait hard-cap). If it
        // is still busy, QUARANTINE the engine instance so a later session
        // cannot reuse this WhisperKit safely; otherwise a fresh ownership is
        // fine.
        if decodeOwnership.isBusy {
            _isQuarantined = true
        } else {
            decodeOwnership = DecodeOwnership()
        }
        currentDecodeSessionID = nil
        lastPartialText = ""
        startTime = nil
    }
}
