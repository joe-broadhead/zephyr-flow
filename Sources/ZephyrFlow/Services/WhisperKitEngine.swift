import Foundation
import Accelerate
import WhisperKit
import ZephyrFlowCore

/// WhisperKit-backed engine. Network only when `allowDownload` is true.
actor WhisperKitEngine: WhisperEngineProtocol {
    private(set) var isReady = false
    private(set) var modelName = "WhisperKit"

    private var kit: WhisperKit?
    private var audioSamples: [Float] = []
    private var isStreaming = false
    private var startTime: Date?

    /// Soft cap for in-memory PCM (~60s @ 16 kHz). Longer dictations keep the most recent audio only.
    private static let maxSampleCount = 16_000 * 60

    /// Decode once, on-device, with Whisper's own quality gates (not string filters).
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
        concurrentWorkerCount: 4
    )

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
        _ = onPartial // hold-to-talk finalizes once; live partials would race WhisperKit/NSProgress
        guard isReady, kit != nil else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }

        audioSamples = []
        startTime = Date()
        isStreaming = true
    }

    func appendAudio(_ samples: [Float]) async {
        guard isStreaming else { return }
        audioSamples.append(contentsOf: samples)
        if audioSamples.count > Self.maxSampleCount {
            audioSamples.removeFirst(audioSamples.count - Self.maxSampleCount)
            ZFLog.debug("WhisperKit buffer capped at ~60s (keeping newest audio)")
        }
    }

    func stopAndFinalize() async throws -> FinalTranscription {
        guard isStreaming else { throw WhisperEngineError.notStreaming }

        let duration = Date().timeIntervalSince(startTime ?? Date())
        let samples = audioSamples
        let rms = Self.rms(of: samples)
        let seconds = Double(samples.count) / 16_000.0
        ZFLog.info(
            "Whisper finalize samples=\(samples.count) (~\(String(format: "%.2f", seconds))s) rms=\(String(format: "%.5f", rms))"
        )

        // Need a meaningful amount of audio before calling the model.
        // Threshold is signal quality (duration + energy), not content filtering.
        guard samples.count >= 1_600 else {
            cleanup()
            return FinalTranscription(
                rawText: "",
                processedText: "",
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
            let results = try await kit.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodeOptions
            )
            raw = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            cleanup()
            throw WhisperEngineError.transcriptionFailed(error.localizedDescription)
        }

        cleanup()
        return FinalTranscription(
            rawText: raw,
            processedText: raw,
            duration: duration,
            modelUsed: modelName
        )
    }

    func cancel() async {
        cleanup()
    }

    // MARK: - Helpers

    nonisolated private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    private func cleanup() {
        audioSamples = []
        isStreaming = false
    }
}
