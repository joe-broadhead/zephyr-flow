import Foundation
import Accelerate
import WhisperKit
import ZephyrFlowCore

/// WhisperKit-backed engine. Network only when `allowDownload` is true.
///
/// Live partials use a **single-flight** rolling-window decode loop so we never
/// run concurrent `transcribe` calls (WhisperKit/NSProgress races → SIGSEGV).
actor WhisperKitEngine: WhisperEngineProtocol {
    private(set) var isReady = false
    private(set) var modelName = "WhisperKit"

    private var kit: WhisperKit?
    private var onPartial: (@Sendable (PartialTranscription) -> Void)?
    private var audioSamples: [Float] = []
    private var isStreaming = false
    private var isFinalizing = false
    private var decodeInFlight = false
    private var startTime: Date?
    private var lastPartialText = ""
    private var partialLoopTask: Task<Void, Never>?

    /// Soft cap for in-memory PCM (~60s @ 16 kHz). Longer dictations keep the most recent audio only.
    private static let maxSampleCount = StreamingPartialWindow.sampleRate * 60

    /// Shared quality gates. `concurrentWorkerCount: 1` avoids internal parallel races.
    private static let decodeOptions = DecodingOptions(
        verbose: false,
        task: .transcribe,
        temperature: 0.0,
        temperatureFallbackCount: 5,
        usePrefillPrompt: true,
        usePrefillCache: true,
        detectLanguage: true,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        wordTimestamps: false,
        windowClipTime: 1.0,
        suppressBlank: true,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        noSpeechThreshold: 0.6,
        concurrentWorkerCount: 1
    )

    /// Faster partial pass (fewer temperature fallbacks).
    private static let partialDecodeOptions = DecodingOptions(
        verbose: false,
        task: .transcribe,
        temperature: 0.0,
        temperatureFallbackCount: 1,
        usePrefillPrompt: true,
        usePrefillCache: true,
        detectLanguage: true,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        wordTimestamps: false,
        windowClipTime: 1.0,
        suppressBlank: true,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        noSpeechThreshold: 0.6,
        concurrentWorkerCount: 1
    )

    /// Minimum RMS to bother decoding a partial (skip near-silence).
    private static let minPartialRMS: Float = 0.0008

    /// - Parameter allowDownload: Must be false when downloads are disabled in settings.
    func load(model: ModelIdentifier, allowDownload: Bool) async throws {
        guard model.isWhisperKit else {
            throw WhisperEngineError.modelLoadFailed("Not a WhisperKit model: \(model.rawValue)")
        }

        isReady = false
        ZFLog.info("WhisperKit load model=\(model.rawValue) allowDownload=\(allowDownload)")

        do {
            let pipe = try await WhisperKit(
                model: model.rawValue,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: allowDownload
            )
            self.kit = pipe
            self.modelName = "WhisperKit (\(model.displayName))"
            self.isReady = true
        } catch {
            let hint = allowDownload
                ? error.localizedDescription
                : "\(error.localizedDescription) — enable model downloads in Privacy settings or pick Apple Speech"
            throw WhisperEngineError.modelLoadFailed(hint)
        }
    }

    func load(model: ModelIdentifier) async throws {
        try await load(model: model, allowDownload: false)
    }

    func startStreaming(
        localOnly: Bool,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        // Whisper path is on-device once loaded; localOnly only gates downloads at load time.
        _ = localOnly
        guard isReady, kit != nil else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }

        self.onPartial = onPartial
        audioSamples = []
        lastPartialText = ""
        isFinalizing = false
        decodeInFlight = false
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
            audioSamples.removeFirst(audioSamples.count - Self.maxSampleCount)
            ZFLog.debug("WhisperKit buffer capped at ~60s (keeping newest audio)")
        }
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming else { throw WhisperEngineError.notStreaming }

        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        await waitForDecodeIdle(timeoutNs: StreamingPartialWindow.finalizeWaitNanoseconds)

        let duration = Date().timeIntervalSince(startTime ?? Date())
        let samples = audioSamples
        let rms = Self.rms(of: samples)
        let seconds = Double(samples.count) / Double(StreamingPartialWindow.sampleRate)
        ZFLog.info(
            "Whisper finalize samples=\(samples.count) (~\(String(format: "%.2f", seconds))s) rms=\(String(format: "%.5f", rms)) lastPartialLen=\(lastPartialText.count)"
        )

        guard samples.count >= 1_600 else {
            let fallback = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            cleanup()
            return FinalTranscription(
                rawText: fallback,
                processedText: fallback,
                duration: duration,
                modelUsed: modelName
            )
        }

        guard let kit else {
            cleanup()
            throw WhisperEngineError.notReady
        }

        let raw: String
        do {
            decodeInFlight = true
            defer { decodeInFlight = false }
            let results = try await kit.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodeOptions
            )
            raw = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Prefer last good partial over hard fail when finalize decode errors.
            let fallback = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                ZFLog.info("Whisper finalize failed; using last partial len=\(fallback.count)")
                cleanup()
                return FinalTranscription(
                    rawText: fallback,
                    processedText: fallback,
                    duration: duration,
                    modelUsed: modelName
                )
            }
            cleanup()
            throw WhisperEngineError.transcriptionFailed(error.localizedDescription)
        }

        let finalText = raw.isEmpty ? lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        cleanup()
        return FinalTranscription(
            rawText: finalText,
            processedText: finalText,
            duration: duration,
            modelUsed: modelName
        )
    }

    func cancel() async {
        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        await waitForDecodeIdle(timeoutNs: 1_000_000_000)
        cleanup()
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
        guard !decodeInFlight else { return }
        guard StreamingPartialWindow.canRunPartial(sampleCount: audioSamples.count) else { return }
        guard let kit else { return }

        let slice = StreamingPartialWindow.sliceForPartial(audioSamples)
        let energy = Self.rms(of: slice)
        guard energy >= Self.minPartialRMS else { return }

        decodeInFlight = true
        defer { decodeInFlight = false }

        do {
            let results = try await kit.transcribe(
                audioArray: slice,
                decodeOptions: Self.partialDecodeOptions
            )
            // Drop result if session ended while we were decoding.
            guard isStreaming, !isFinalizing else { return }

            let text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty, text != lastPartialText else { return }
            lastPartialText = text
            // Length only — never log body
            ZFLog.debug("Whisper partial len=\(text.count)")
            onPartial?(PartialTranscription(text: text, isFinal: false))
        } catch {
            if !Task.isCancelled, isStreaming, !isFinalizing {
                ZFLog.debug("Whisper partial decode skipped: \(error.localizedDescription)")
            }
        }
    }

    private func waitForDecodeIdle(timeoutNs: UInt64) async {
        let step: UInt64 = 20_000_000
        var waited: UInt64 = 0
        while decodeInFlight, waited < timeoutNs {
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        if decodeInFlight {
            ZFLog.info("Whisper decode still in flight after wait (\(waited / 1_000_000)ms)")
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
        decodeInFlight = false
        lastPartialText = ""
        startTime = nil
    }
}
