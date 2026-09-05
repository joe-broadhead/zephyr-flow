import Accelerate
import Foundation
import WhisperKit
import ZephyrFlowCore

/// WhisperKit-backed engine. Verified initialization uses a local-only
/// tokenizer adapter; acquisition requires separate model-download consent.
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
    private var audioBuffer = LongDictationAudioBuffer()
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
    private var startedAtNanos: UInt64?
    private var lastPartialText = ""
    private var partialLoopTask: Task<Void, Never>?

    private let finalizationBudgetNanos: UInt64
    private enum NativeDecodeResult: Sendable {
        case value(WhisperChunkTranscript)
        case failed, cancelled, deadlineExceeded
    }
    private enum NativeDecodeError: Error { case failed, deadlineExceeded }
    private struct NativeWork {
        let operation: DecodeOperation
        let task: Task<Void, Never>
        let completion: AsyncStream<NativeDecodeResult>.Continuation
    }
    private var nativeWork: NativeWork?
    var hasOutstandingDecode: Bool { nativeWork != nil }

    init(
        runtimeFactory: @escaping WhisperRuntimeFactory = { try await WhisperKitRuntime.load($0) },
        finalizationBudgetNanos: UInt64 = 120_000_000_000
    ) {
        self.runtimeFactory = runtimeFactory
        self.finalizationBudgetNanos = finalizationBudgetNanos
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
            withoutTimestamps: false,
            wordTimestamps: true,
            windowClipTime: 0.0,
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
        // Streaming uses only the already-loaded runtime. Verified runtime
        // initialization uses the local-only tokenizer hook; the model's
        // download:false flag alone is not the offline guarantee.
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

        self.onPartial = onPartial
        audioBuffer = LongDictationAudioBuffer()
        lastPartialText = ""
        isFinalizing = false
        decodeOwnership = DecodeOwnership()
        startedAtNanos = DispatchTime.now().uptimeNanoseconds
        isStreaming = true

        partialLoopTask?.cancel()
        partialLoopTask = Task { [weak self] in
            await self?.runPartialLoop()
        }
        ZFLog.info("Whisper streaming started (single-flight partials)")
    }

    func appendAudio(_ samples: [Float]) async {
        guard isStreaming, !isFinalizing else { return }
        audioBuffer.append(samples)
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming, let sessionID = currentDecodeSessionID else { throw WhisperEngineError.notStreaming }
        guard !isFinalizing else { throw WhisperEngineError.decodeBusy }
        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        let recording = audioBuffer
        let started = startedAtNanos
        let language = currentLanguage
        let identity = engineIdentity()
        let partial = lastPartialText
        let clock = ContinuousClock()
        let finalizeStarted = clock.now
        let finalizeStartedNanos = DispatchTime.now().uptimeNanoseconds
        let deadline = finalizeStarted.advanced(by: .nanoseconds(Int64(clamping: finalizationBudgetNanos)))
        defer { if currentDecodeSessionID == sessionID { cleanup() } }
        guard let kit, let plan = FinalDecodeChunkPlan.ranges(sampleCount: recording.sampleCount) else {
            throw WhisperEngineError.notReady
        }
        var chunks: [DecodedAudioChunk] = []
        var decodedUniqueSamples = 0
        var termination: EngineResultTermination = .completed
        var warnings: [EngineWarning] = []
        var failureReason: String?
        do {
            if recording.sampleCount < 1_600 {
                warnings.append(.shortAudioFallback)
                failureReason = "short audio; final decode not performed"
            } else {
                for range in plan {
                    try Task.checkCancellation()
                    guard currentDecodeSessionID == sessionID, isStreaming else { throw CancellationError() }
                    guard clock.now < deadline else { throw NativeDecodeError.deadlineExceeded }
                    guard let samples = recording.samples(in: range) else { throw NativeDecodeError.failed }
                    let result = try await runTranscribe(
                        kit: kit, samples: samples,
                        options: currentDecodeOptions ?? decodeOptions(language: language), purpose: .final,
                        deadline: deadline)
                    guard currentDecodeSessionID == sessionID, isStreaming else { throw CancellationError() }
                    // Counts unique original ranges, not repeated overlap decode
                    // effort. Native completion is not semantic/WER evidence.
                    decodedUniqueSamples = range.upperBound
                    chunks.append(DecodedAudioChunk(samples: range, text: result.text, words: result.words))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case NativeDecodeError.deadlineExceeded = error {
                termination = .deadlineExceeded
                warnings.append(.deadlineExceeded)
                failureReason = "final chunk decode deadline exceeded"
            } else {
                termination = .failed
                failureReason = "final chunk decode failed"
            }
        }
        try Task.checkCancellation()
        guard currentDecodeSessionID == sessionID, isStreaming else { throw CancellationError() }
        let text: String
        var complete = false
        switch LongDictationStitcher.stitch(chunks, expectedSampleCount: recording.sampleCount) {
        case .stitched(let stitched):
            text = stitched
            complete = failureReason == nil && !stitched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .incomplete(let hypotheses, let reason):
            text = hypotheses.isEmpty ? partial : hypotheses
            failureReason = failureReason ?? reason
        }
        if !complete { warnings.append(.partialFallback) }
        if recording.rejectedSamples > 0 {
            warnings.append(.truncation)
            failureReason = "ten-minute input limit exceeded; excess counted, prefix retained"
        }
        let accepted = UInt64(recording.sampleCount)
        let (observed, overflow) = accepted.addingReportingOverflow(recording.rejectedSamples)
        let accounting = EngineFrameAccounting(
            capturedSourceSamples: overflow ? .max : observed,
            deliveredEngineSamples: accepted,
            decodedEngineSamples: UInt64(decodedUniqueSamples),
            droppedSourceSamples: recording.rejectedSamples)
        return EngineResult(
            text: text,
            completeness: recording.rejectedSamples > 0 ? .truncated : (complete ? .complete : .partial),
            frameAccounting: accounting,
            engine: identity,
            languageRequested: language.bcp47,
            languageDetected: nil,
            confidence: nil, confidenceSource: nil,
            startedAtUptimeNanos: started,
            endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
            inferenceDurationNanos: DispatchTime.now().uptimeNanoseconds &- finalizeStartedNanos,
            warnings: warnings,
            fallbackReason: failureReason,
            termination: termination)
    }

    private func engineIdentity() -> EngineIdentity {
        EngineIdentity(
            kind: .whisper, modelName: modelName,
            modelVersion: nil, modelDigest: verifiedDigest)
    }

    func quarantine() async {
        _isQuarantined = true
        pendingLoadToken = nil
        currentDecodeSessionID = nil
        if let work = nativeWork { cancelDecodeWaiter(work.operation) }
    }

    func cancel() async {
        // Invalidate publication before any suspension, even if the native
        // initializer ignores task cancellation and returns much later.
        pendingLoadToken = nil
        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        // Cancel the waiter, never join noncooperative native work. That work
        // retains this engine/runtime and its one chunk until actual completion.
        if let work = nativeWork { cancelDecodeWaiter(work.operation) }
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
        purpose: DecodePurpose,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> WhisperChunkTranscript {
        guard let sessionID = currentDecodeSessionID else {
            throw WhisperEngineError.notReady
        }
        let clock = ContinuousClock()
        let deadline = deadline ?? clock.now.advanced(by: .nanoseconds(Int64(clamping: finalizationBudgetNanos)))
        try await waitForDecodeIdle(sessionID: sessionID, deadline: deadline)
        guard !Task.isCancelled, isStreaming, currentDecodeSessionID == sessionID, !_isQuarantined else {
            throw CancellationError()
        }
        guard clock.now < deadline else { throw NativeDecodeError.deadlineExceeded }

        let now = DispatchTime.now().uptimeNanoseconds
        let op = decodeOwnership.begin(
            purpose: purpose,
            sessionID: sessionID,
            nowNanos: now)
        guard let op else {
            throw WhisperEngineError.decodeBusy
        }
        let (stream, completion) = AsyncStream.makeStream(
            of: NativeDecodeResult.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            let result: NativeDecodeResult
            do {
                try Task.checkCancellation()
                if purpose == .final {
                    result = .value(try await kit.transcribeChunk(samples: samples, options: options))
                } else {
                    result = .value(
                        WhisperChunkTranscript(
                            text: try await kit.transcribe(samples: samples, options: options), words: nil))
                }
            } catch is CancellationError { result = .cancelled } catch { result = .failed }
            finishNativeDecode(op, result: result)
        }
        nativeWork = NativeWork(operation: op, task: worker, completion: completion)
        let timer = Task {
            do { try await clock.sleep(until: deadline) } catch { return }
            expireDecode(op)
        }
        defer {
            timer.cancel()
            completion.finish()
        }
        let result = await withTaskCancellationHandler {
            for await result in stream { return result }
            return NativeDecodeResult.cancelled
        } onCancel: {
            worker.cancel()
            completion.finish()
            Task { await self.cancelDecodeWaiter(op) }
        }
        try Task.checkCancellation()
        guard currentDecodeSessionID == sessionID, isStreaming else { throw CancellationError() }
        guard clock.now < deadline else { throw NativeDecodeError.deadlineExceeded }
        switch result {
        case .value(let value): return value
        case .cancelled: throw CancellationError()
        case .deadlineExceeded: throw NativeDecodeError.deadlineExceeded
        case .failed: throw NativeDecodeError.failed
        }
    }

    private func cancelDecodeWaiter(_ op: DecodeOperation) {
        guard let work = nativeWork, work.operation == op else { return }
        _ = decodeOwnership.cancel(op)
        work.task.cancel()
        work.completion.yield(.cancelled)
        work.completion.finish()
    }

    private func expireDecode(_ op: DecodeOperation) {
        guard let work = nativeWork, work.operation == op else { return }
        _isQuarantined = true
        work.task.cancel()
        work.completion.yield(.deadlineExceeded)
        work.completion.finish()
    }

    private func finishNativeDecode(_ op: DecodeOperation, result: NativeDecodeResult) {
        guard let work = nativeWork, work.operation == op else { return }
        nativeWork = nil
        _ = decodeOwnership.finish(
            op,
            outcome: {
                switch result {
                case .value: return .completed
                case .cancelled: return .cancelled
                case .deadlineExceeded: return .deadlineExceeded
                case .failed: return .degraded
                }
            }())
        work.completion.yield(result)
        work.completion.finish()
    }

    private func waitForDecodeIdle(sessionID: SessionID, deadline: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        while decodeOwnership.isBusy {
            try Task.checkCancellation()
            guard isStreaming, currentDecodeSessionID == sessionID else { throw CancellationError() }
            guard clock.now < deadline else {
                _isQuarantined = true
                throw NativeDecodeError.deadlineExceeded
            }
            try await Task.sleep(nanoseconds: 10_000_000)
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
        guard StreamingPartialWindow.canRunPartial(sampleCount: audioBuffer.sampleCount) else { return }
        guard let kit else { return }

        let slice = audioBuffer.recentSamples()
        let energy = Self.rms(of: slice)
        guard energy >= Self.minPartialRMS else { return }

        do {
            let text = try await runTranscribe(
                kit: kit, samples: slice,
                options: partialDecodeOptions(language: currentLanguage),
                purpose: .partial
            )
            .text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard isStreaming, !isFinalizing else { return }
            guard !text.isEmpty, text != lastPartialText else { return }
            lastPartialText = text
            ZFLog.debug("Whisper partial len=\(text.count)")
            onPartial?(PartialTranscription(text: text, isFinal: false))
        } catch {
            if !Task.isCancelled, isStreaming, !isFinalizing {
                ZFLog.debug("Whisper partial decode skipped")
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
        audioBuffer = LongDictationAudioBuffer()
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
        startedAtNanos = nil
    }
}
