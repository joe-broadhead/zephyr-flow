import Foundation
import Speech
import AVFoundation
import Accelerate
import ZephyrFlowCore

/// On-device transcription via Apple's Speech framework.
/// Owns its own AVAudioEngine and feeds **native-format** buffers to SFSpeech
/// (required for reliable recognition — 16 kHz converted PCM often yields empty results).
actor AppleSpeechEngine: WhisperEngineProtocol {
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

    func levels() -> [Float] { latestLevels }

    func load(model: ModelIdentifier) async throws {
        let identifier = Locale.current.identifier
        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()

        guard let speechRecognizer else {
            throw WhisperEngineError.modelLoadFailed("No speech recognizer available")
        }

        // Don't block on auth prompts during load — mark ready and enforce at startStreaming.
        let status = SFSpeechRecognizer.authorizationStatus()
        ZFLog.info("Speech auth status=\(status.rawValue) locale=\(speechRecognizer.locale.identifier) available=\(speechRecognizer.isAvailable) onDevice=\(speechRecognizer.supportsOnDeviceRecognition)")

        recognizer = speechRecognizer
        modelName = "Apple Speech (\(speechRecognizer.locale.identifier))"
        isReady = true
        ZFLog.info("AppleSpeechEngine ready")
    }

    func startStreaming(
        localOnly: Bool,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        guard isReady, let recognizer else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }

        // Auth — request if needed (caller should activate app so dialogs appear)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            let granted = await requestAuth()
            guard granted else {
                throw WhisperEngineError.transcriptionFailed("Speech Recognition permission denied — System Settings → Privacy & Security → Speech Recognition")
            }
        }
        let micOK = await requestMic()
        guard micOK else {
            throw WhisperEngineError.transcriptionFailed("Microphone permission denied — System Settings → Privacy & Security → Microphone")
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
        ZFLog.info("Recognition supportsOnDevice=\(recognizer.supportsOnDeviceRecognition) requireOnDevice=\(request.requiresOnDeviceRecognition) localOnly=\(localOnly)")

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

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { await self.handleRecognition(result: result, error: error) }
        }
    }

    /// External PCM path unused — this engine captures itself.
    func appendAudio(_ samples: [Float]) async {
        // no-op (manages own audio)
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming else { throw WhisperEngineError.notStreaming }

        ZFLog.info("stopAndFinalize accumulated_len=\(accumulated.count) sawFinal=\(sawFinal)")

        // Stop mic first
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        // Signal end of audio to recognizer
        request?.endAudio()

        // Wait for final callback (up to ~2s), polling accumulated
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if sawFinal { break }
            // If we already have text and a short quiet period, accept it
            if !accumulated.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if sawFinal || !accumulated.isEmpty { break }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Date().timeIntervalSince(startTime ?? Date())
        let err = lastError
        cleanupStream()

        ZFLog.info("Final text len=\(finalText.count) duration=\(String(format: "%.2f", duration)) err=\(err ?? "nil")")

        if finalText.isEmpty, let err {
            throw WhisperEngineError.transcriptionFailed(err)
        }

        return FinalTranscription(
            rawText: finalText,
            processedText: finalText,
            duration: duration,
            modelUsed: modelName
        )
    }

    func cancel() async {
        task?.cancel()
        request?.endAudio()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        cleanupStream()
    }

    // MARK: - Private

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            // Never overwrite a good partial with an empty final (common on cancel/end).
            if !text.isEmpty {
                accumulated = text
                onPartial?(PartialTranscription(text: text, isFinal: result.isFinal))
            }
            if result.isFinal {
                sawFinal = true
            }
            // Never log transcript content — lengths only (PII).
            ZFLog.info("partial isFinal=\(result.isFinal) len=\(text.count) kept=\(accumulated.count)")
        }
        if let error {
            let ns = error as NSError
            // 1 = cancelled, 203 = no speech, 1110 = no speech detected — keep partials
            // 201 = Siri/Dictation disabled system-wide (blocks SFSpeechRecognizer)
            lastError = Self.friendlySpeechError(ns)
            ZFLog.error("recognition error domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
            if !accumulated.isEmpty {
                sawFinal = true
                lastError = nil // we have usable text
            }
        }
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
