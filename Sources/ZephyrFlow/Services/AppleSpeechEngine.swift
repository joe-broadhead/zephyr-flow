import AVFoundation
import Accelerate
import Foundation
import Speech
import ZephyrFlowCore

/// On-device transcription via Apple's Speech framework.
/// Owns its own AVAudioEngine and feeds **native-format** buffers to SFSpeech
/// (required for reliable recognition — 16 kHz converted PCM often yields empty results).
actor AppleSpeechEngine: WhisperEngineProtocol {
    public var isQuarantined: Bool { false }  // never quarantines
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
        // Apple Speech loads system recognizers; there is no downloaded
        // artifact to verify. `verifiedFolder` is accepted for protocol
        // uniformity and ignored.
        let identifier = Locale.current.identifier
        let speechRecognizer =
            SFSpeechRecognizer(locale: Locale(identifier: identifier))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()

        guard let speechRecognizer else {
            throw WhisperEngineError.modelLoadFailed("No speech recognizer available")
        }

        // Don't block on auth prompts during load — mark ready and enforce at startStreaming.
        let status = SFSpeechRecognizer.authorizationStatus()
        ZFLog.info(
            "Speech auth status=\(status.rawValue) locale=\(speechRecognizer.locale.identifier) available=\(speechRecognizer.isAvailable) onDevice=\(speechRecognizer.supportsOnDeviceRecognition)"
        )

        recognizer = speechRecognizer
        modelName = "Apple Speech (\(speechRecognizer.locale.identifier))"
        isReady = true
        ZFLog.info("AppleSpeechEngine ready")
    }

    func startStreaming(
        sessionID: SessionID,
        localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        guard isReady else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        // JOE-2254: construct the recognizer for the requested locale with an
        // explicit fallback policy — NEVER a silent en-US substitution.
        let recognizer: SFSpeechRecognizer
        if let bcp47 = language.bcp47 {
            guard let localeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: bcp47)) else {
                throw WhisperEngineError.modelLoadFailed(
                    "Speech recognition is unavailable for \(bcp47). Pick another language or use Auto.")
            }
            recognizer = localeRecognizer
        } else {
            guard let current = self.recognizer ?? SFSpeechRecognizer() else {
                throw WhisperEngineError.notReady
            }
            recognizer = current
        }
        // Local Only preflight: on-device recognition must be available; never
        // silently fall back to network recognition.
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            throw WhisperEngineError.modelLoadFailed(
                "Local Only: on-device speech is unavailable for \(recognizer.locale.identifier). Download the language pack in System Settings → Apple Intelligence & Siri, or turn off Local Only."
            )
        }
        self.recognizer = recognizer
        currentLanguage = language
        // JOE-2253: unique token per start; callbacks carry it.
        recognitionTracker.start(token: RecognitionToken())

        // Auth — request if needed (caller should activate app so dialogs appear)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            let granted = await requestAuth()
            guard granted else {
                throw WhisperEngineError.transcriptionFailed(
                    "Speech Recognition permission denied — System Settings → Privacy & Security → Speech Recognition")
            }
        }
        let micOK = await requestMic()
        guard micOK else {
            throw WhisperEngineError.transcriptionFailed(
                "Microphone permission denied — System Settings → Privacy & Security → Microphone")
        }

        guard recognizer.isAvailable else {
            throw WhisperEngineError.transcriptionFailed("Speech recognizer unavailable")
        }

        // C1 (Opus): Local Only must fail closed — never stream audio to Apple servers.
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            throw WhisperEngineError.transcriptionFailed(
                "Local Only: on-device speech is unavailable for \(recognizer.locale.identifier). Download the language pack in System Settings → Apple Intelligence & Siri, or turn off Local Only."
            )
        }

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
            Task { await self.handleRecognition(token: token, result: result, error: error) }
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

        ZFLog.info("Final text len=\(finalText.count) duration=\(String(format: "%.2f", duration)) err=\(err ?? "nil")")

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
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        // JOE-2253: reject callbacks whose token is no longer current.
        guard recognitionTracker.isCurrent(token: token) else {
            ZFLog.info("stale recognition callback rejected (token mismatch)")
            return
        }
        if let result {
            let text = result.bestTranscription.formattedString
            // Never overwrite a good partial with an empty final (common on
            // cancel/end) — tracker preserves latest usable partial.
            _ = recognitionTracker.notePartial(token: token, text: text)
            if !text.isEmpty {
                accumulated = text
                onPartial?(PartialTranscription(text: text, isFinal: result.isFinal))
            }
            // Never log transcript content — lengths only (PII).
            ZFLog.info("partial isFinal=\(result.isFinal) len=\(text.count) kept=\(accumulated.count)")
            if result.isFinal {
                sawFinal = true
                let outcome = recognitionTracker.noteFinal(token: token, hasText: !text.isEmpty)
                ZFLog.info("final event outcome=\(outcome.rawValue) len=\(text.count)")
                finishRecognition()
            }
        }
        if let error {
            let ns = error as NSError
            // 1 = cancelled, 203 = no speech, 1110 = no speech detected — keep partials
            // 201 = Siri/Dictation disabled system-wide (blocks SFSpeechRecognizer)
            let friendly = Self.friendlySpeechError(ns)
            lastError = friendly
            let outcome = recognitionTracker.noteError(
                token: token,
                code: Int32(ns.code),
                friendly: friendly)
            ZFLog.info("recognition error outcome=\(outcome.rawValue) domain=\(ns.domain) code=\(ns.code)")
            ZFLog.error("recognition error domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
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

    private func requestAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
    }

    nonisolated private static func friendlySpeechError(_ ns: NSError) -> String {
        // kLSRErrorDomain 201 — system Dictation/Siri master switch is off
        if ns.domain == "kLSRErrorDomain" && ns.code == 201 {
            return "macOS Dictation is turned off. Enable it in System Settings → Keyboard → Dictation, then try again."
        }
        if ns.localizedDescription.localizedCaseInsensitiveContains("Siri and Dictation are disabled") {
            return "macOS Dictation is turned off. Enable it in System Settings → Keyboard → Dictation, then try again."
        }
        return ns.localizedDescription
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
