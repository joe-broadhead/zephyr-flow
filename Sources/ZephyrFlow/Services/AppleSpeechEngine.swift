import AVFoundation
import Accelerate
import Foundation
import Speech
import ZephyrFlowCore

/// Snapshot framework callback data before crossing onto the engine actor.
/// NSError/SFSpeechRecognitionResult never cross that boundary, and arbitrary
/// error descriptions/userInfo never enter presentation or diagnostic output.
struct AppleSpeechCallback: Sendable {
    let text: String?
    let isFinal: Bool
    let errorCode: Int32?
    let errorMessage: String?

    init(text: String?, isFinal: Bool, error: NSError?) {
        self.text = text
        self.isFinal = isFinal
        self.errorCode = error.map { Int32(clamping: $0.code) }
        if let error {
            if error.domain == "kLSRErrorDomain", error.code == 201 {
                self.errorMessage =
                    "macOS Dictation is turned off. Enable it in System Settings → Keyboard → Dictation, then try again."
            } else {
                self.errorMessage = "Speech recognition failed. Try again or choose another on-device engine."
            }
        } else {
            self.errorMessage = nil
        }
    }
}

/// On-device transcription via Apple's Speech framework.
/// Owns its own AVAudioEngine and feeds **native-format** buffers to SFSpeech
/// (required for reliable recognition — 16 kHz converted PCM often yields empty results).
actor AppleSpeechEngine: WhisperEngineProtocol {
    public var isQuarantined: Bool { false }  // never quarantines
    func quarantine() async {}  // Apple Speech never quarantines
    public var verifiedDigest: String? { nil }
    public func recordVerifiedDigest(_ digest: String?) {}
    private(set) var isReady = false
    private(set) var modelName = "Apple Speech"

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onPartial: (@Sendable (PartialTranscription) -> Void)?
    private var accumulated = ""
    private var startTime: Date?
    private var isStreaming = false
    private var latestLevels: [Float] = Array(repeating: 0.05, count: 24)
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []
    private var sawFinal = false
    private var lastError: String?
    // JOE-2253: tokenized callbacks + event-driven finalization.
    private var recognitionTracker = SpeechRecognitionTracker()
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var finalizationPending = false
    // JOE-2254: session language snapshot (for result metadata).
    private var currentLanguage: SupportedLanguage = .auto

    func levels() -> [Float] { latestLevels }

    func load(model: ModelIdentifier, verifiedFolder: String? = nil) async throws {
        guard model == .appleSpeech, verifiedFolder == nil else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        // No locale fallback or permission prompt here. The coordinator must
        // preflight the requested language before publishing this candidate.
        recognizer = nil
        modelName = "Apple Speech"
        isReady = true
        ZFLog.info("Apple Speech initialized; capability preflight required")
    }

    func preflight(localOnly: Bool, language: SupportedLanguage) async throws {
        try validateCapabilities(localOnly: localOnly, language: language)
    }

    private func validateCapabilities(localOnly: Bool, language: SupportedLanguage) throws {
        guard isReady else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        // Auto means the user's current locale, not silent en-US substitution
        // or arbitrary SFSpeechRecognizer defaults. Fixed language stays exact.
        let locale = Locale(identifier: language.bcp47 ?? Locale.current.identifier)
        let candidate = SFSpeechRecognizer(locale: locale)
        let capabilities = SpeechReadinessCapabilities(
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            requestedLocaleAvailable: candidate != nil,
            recognizerAvailable: candidate?.isAvailable == true,
            supportsOnDevice: candidate?.supportsOnDeviceRecognition == true)
        _ = try capabilities.validate(localOnly: localOnly)
        recognizer = candidate
        modelName = "Apple Speech (\(locale.identifier))"
    }

    func startStreaming(
        sessionID: SessionID,
        localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        guard isReady else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        // Recheck at capture admission as permissions/capabilities can change
        // after preparation. All checks are synchronous; no permission request
        // or reentrant await can start capture after an intervening cancel.
        try validateCapabilities(localOnly: localOnly, language: language)
        guard let recognizer else { throw WhisperEngineError.notReady }
        currentLanguage = language
        // JOE-2253: unique token per start; callbacks carry it.
        recognitionTracker.start(token: RecognitionToken())

        self.onPartial = onPartial
        self.accumulated = ""
        self.startTime = Date()
        self.isStreaming = true
        self.sawFinal = false
        self.lastError = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            // Only reachable when localOnly == false
            request.requiresOnDeviceRecognition = false
            ZFLog.info("On-device speech unavailable — network speech allowed (Local Only off)")
        }
        request.taskHint = .dictation
        self.request = request
        ZFLog.info(
            "Recognition supportsOnDevice=\(recognizer.supportsOnDeviceRecognition) requireOnDevice=\(request.requiresOnDeviceRecognition) localOnly=\(localOnly)"
        )

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Use nil format to get the node's native format (Apple-recommended)
        let nativeFormat = input.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            cleanupStream()
            throw WhisperEngineError.transcriptionFailed("No microphone input format available")
        }

        ZFLog.info("Starting capture sr=\(nativeFormat.sampleRate) ch=\(nativeFormat.channelCount)")

        input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            // Levels on actor
            let copy = Self.rmsLevels(from: buffer)
            Task { await self.updateLevels(copy) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cleanupStream()
            throw WhisperEngineError.transcriptionFailed("Audio engine failed: \(error.localizedDescription)")
        }
        self.audioEngine = engine

        let token = recognitionTracker.currentToken ?? RecognitionToken()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let callback = AppleSpeechCallback(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                error: error.map { $0 as NSError })
            Task { await self.handleRecognition(token: token, callback: callback) }
        }
    }

    /// External PCM path unused — this engine captures itself.
    func appendAudio(_ samples: [Float]) async {
        // no-op (manages own audio)
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming else { throw WhisperEngineError.notStreaming }

        ZFLog.info("stopAndFinalize accumulated_len=\(accumulated.count) sawFinal=\(sawFinal)")

        // Signal end of audio to the recognizer, then WAIT for the final
        // event (final result / terminal error / cancellation) until a
        // bounded deadline — never break early merely because partial text
        // exists (JOE-2253 event-driven finalization).
        request?.endAudio()

        if !sawFinal && !finalizationPending {
            finalizationPending = true
            // Review R3.1: race the final event against a hard deadline with
            // an actor-owned, cancel-aware wait (cannot hang past 2s).
            await waitForFinalEvent(deadlineNanosAhead: 2_000_000_000)
            // Deadline reached: a non-empty partial is only partial/degraded.
            if !sawFinal {
                let outcome = recognitionTracker.noteDeadline()
                ZFLog.info("finalize deadline outcome=\(outcome.rawValue)")
            }
        }

        // Exactly-once release of task/tap/continuations.
        finishRecognition()

        let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Date().timeIntervalSince(startTime ?? Date())
        let err = lastError
        cleanupStream()

        ZFLog.info(
            "Final text len=\(finalText.count) duration=\(String(format: "%.2f", duration)) hasError=\(err != nil)")

        if finalText.isEmpty, let err {
            throw WhisperEngineError.transcriptionFailed(err)
        }

        // Apple Speech: completeness derived from the final callback + error
        // state. A rolling partial is never promoted to `complete`.
        // Review R3.1: `.complete` requires a genuine final event with NO
        // error and usable text. Any error keeps the result partial/degraded.
        let completeness = SpeechCompletenessPolicy.completeness(
            sawFinal: sawFinal, error: err, hasText: !finalText.isEmpty)
        let warnings = SpeechCompletenessPolicy.warnings(
            sawFinal: sawFinal, error: err, hasText: !finalText.isEmpty)
        let accounting = EngineFrameAccounting(
            capturedSourceSamples: 0,
            deliveredEngineSamples: 0,
            decodedEngineSamples: 0,
            droppedSourceSamples: 0)
        return EngineResult(
            text: finalText,
            completeness: completeness,
            frameAccounting: accounting,
            engine: EngineIdentity(
                kind: .appleSpeech, modelName: modelName,
                modelVersion: nil, modelDigest: nil),
            languageRequested: currentLanguage.bcp47,
            languageDetected: currentLanguage.bcp47,
            confidence: nil, confidenceSource: nil,
            startedAtUptimeNanos: nil,
            endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
            inferenceDurationNanos: UInt64(duration * 1_000_000_000),
            warnings: warnings,
            fallbackReason: (sawFinal && err == nil) ? nil : "rolling partial / degraded",
            termination: err == nil ? .completed : .failed)
    }

    func cancel() async {
        let token = recognitionTracker.currentToken ?? RecognitionToken()
        _ = recognitionTracker.cancel(token: token)
        finishRecognition()
        cleanupStream()
    }

    // MARK: - Private

    /// Waits for the final recognition event (resumed exactly once by
    /// finishRecognition from any terminal path).
    private func awaitFinalEvent() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finalContinuation = cont
            if sawFinal || recognitionTracker.finalEvent != nil {
                finishRecognition()
            }
        }
    }

    /// Review R3.1: bounded, cancel-aware wait for the final recognition event.
    /// Runs ON the actor so it can mutate finalContinuation; the deadline task
    /// is a separate unstructured task that calls the actor to resume the
    /// continuation if the final event never arrives — the wait can never hang.
    private func waitForFinalEvent(deadlineNanosAhead: UInt64) async {
        // The deadline task cancels the wait by resuming the continuation
        // exactly once via the actor.
        // The deadline task guarantees the wait is bounded: after the
        // deadline it hops to the actor and resumes the continuation exactly
        // once (if still pending). The continuation itself is stored on the
        // actor, so no Sendable closure touches actor state.
        let deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: deadlineNanosAhead)
            await self?.cancelFinalizationWait()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finalContinuation = cont
            if sawFinal || recognitionTracker.finalEvent != nil {
                finishRecognition()  // resumes cont exactly once
            }
        }
        deadlineTask.cancel()
    }

    /// Actor-side: resume the finalization continuation if still pending.
    private func cancelFinalizationWait() {
        if let cont = finalContinuation {
            finalContinuation = nil
            cont.resume()
        }
    }

    private func handleRecognition(
        token: RecognitionToken,
        callback: AppleSpeechCallback
    ) {
        // JOE-2253: reject callbacks whose token is no longer current.
        guard recognitionTracker.isCurrent(token: token) else {
            ZFLog.info("stale recognition callback rejected (token mismatch)")
            return
        }
        if let text = callback.text {
            // Never overwrite a good partial with an empty final (common on
            // cancel/end) — tracker preserves latest usable partial.
            _ = recognitionTracker.notePartial(token: token, text: text)
            if !text.isEmpty {
                accumulated = text
                onPartial?(PartialTranscription(text: text, isFinal: callback.isFinal))
            }
            // Never log transcript content — lengths only (PII).
            ZFLog.info("partial isFinal=\(callback.isFinal) len=\(text.count) kept=\(accumulated.count)")
            if callback.isFinal {
                sawFinal = true
                let outcome = recognitionTracker.noteFinal(token: token, hasText: !text.isEmpty)
                ZFLog.info("final event outcome=\(outcome.rawValue) len=\(text.count)")
                finishRecognition()
            }
        }
        if let code = callback.errorCode {
            let friendly = callback.errorMessage ?? "Speech recognition failed."
            lastError = friendly
            let outcome = recognitionTracker.noteError(
                token: token,
                code: code,
                friendly: friendly)
            ZFLog.error("recognition error outcome=\(outcome.rawValue) code=\(code)")
            // Review R3.1: preserve the error. An errored partial must NEVER
            // be promoted to `.complete` — keeping lastError set makes the
            // completeness mapping below return .partial/.degraded, never
            // .complete, even though usable text exists.
            if !accumulated.isEmpty {
                sawFinal = false  // no final event arrived; only partial text
            }
            finishRecognition()
        }
    }

    /// Exactly-once terminal path: cancels/releases the task and resumes any
    /// finalization waiter. Called from every terminal path (success, error,
    /// cancel, reload, shutdown).
    private func finishRecognition() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        if recognitionTracker.markResumed() {
            finalContinuation?.resume()
            finalContinuation = nil
        }
        for waiter in finalWaiters {
            waiter.resume()
        }
        finalWaiters = []
        finalizationPending = false
    }

    private func updateLevels(_ sampleLevel: Float) {
        var next = latestLevels
        next.removeFirst()
        next.append(sampleLevel)
        latestLevels = next
    }

    private func cleanupStream() {
        task = nil
        request = nil
        onPartial = nil
        audioEngine = nil
        isStreaming = false
        latestLevels = Array(repeating: 0.05, count: 24)
    }

    nonisolated private static func rmsLevels(from buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0.05 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0.05 }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
        return min(1.0, max(0.03, rms * 8))
    }
}
