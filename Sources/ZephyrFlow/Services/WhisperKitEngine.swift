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
    /// JOE-2250: exclusive cancellable decode ownership (single-flight).
    private var decodeOwnership = DecodeOwnership()
    private var currentDecodeSessionID: SessionID?
    private var startTime: Date?
    private var lastPartialText = ""
    private var partialLoopTask: Task<Void, Never>?

    private static let maxSampleCount = StreamingPartialWindow.sampleRate * 60

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
        sessionID: SessionID,
        localOnly: Bool,
        language: SupportedLanguage,
        onPartial: @escaping @Sendable (PartialTranscription) -> Void
    ) async throws {
        _ = localOnly
        guard isReady, kit != nil else { throw WhisperEngineError.notReady }
        guard !isStreaming else { throw WhisperEngineError.alreadyStreaming }
        currentDecodeSessionID = sessionID

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
            audioSamples.removeFirst(audioSamples.count - Self.maxSampleCount)
            ZFLog.debug("WhisperKit buffer capped at ~60s (keeping newest audio)")
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
            let accounting = EngineFrameAccounting(capturedSourceSamples: UInt64(samples.count),
                                                   deliveredEngineSamples: 0,
                                                   decodedEngineSamples: 0,
                                                   droppedSourceSamples: 0)
            cleanup()
            return EngineResult(text: fallback,
                                completeness: .partial,
                                frameAccounting: accounting,
                                engine: engineIdentity(),
                                languageRequested: nil, languageDetected: nil,
                                confidence: nil, confidenceSource: nil,
                                startedAtUptimeNanos: startTime?.timeIntervalSince1970 != nil ? DispatchTime.now().uptimeNanoseconds : nil,
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
            raw = try await runTranscribe(kit: kit, samples: samples, options: currentDecodeOptions ?? decodeOptions(language: currentLanguage),
                                          purpose: .final)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let fallback = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                ZFLog.info("Whisper finalize failed; using last partial len=\(fallback.count)")
                let accounting = EngineFrameAccounting(capturedSourceSamples: UInt64(samples.count),
                                                       deliveredEngineSamples: 0,
                                                       decodedEngineSamples: 0,
                                                       droppedSourceSamples: 0)
                cleanup()
                // A final-decode failure with a rolling partial is NEVER
                // `complete` (JOE-2252): it is `partial` with a warning.
                return EngineResult(text: fallback,
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

        let finalText = raw.isEmpty
            ? lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            : raw
        // Frame evidence: captured == delivered (16 kHz reference), decoded
        // == delivered — required for a `complete` claim.
        let captured = UInt64(samples.count)
        let delivered = UInt64(samples.count)
        let accounting = EngineFrameAccounting(capturedSourceSamples: captured,
                                               deliveredEngineSamples: delivered,
                                               decodedEngineSamples: delivered,
                                               droppedSourceSamples: 0)
        let completeness: EngineResultCompleteness = raw.isEmpty ? .partial : .complete
        let warnings: [EngineWarning] = raw.isEmpty ? [.partialFallback] : []
        cleanup()
        return EngineResult(text: finalText,
                            completeness: completeness,
                            frameAccounting: accounting,
                            engine: engineIdentity(),
                            languageRequested: nil, languageDetected: nil,
                            confidence: nil, confidenceSource: nil,
                            startedAtUptimeNanos: nil,
                            endedAtUptimeNanos: DispatchTime.now().uptimeNanoseconds,
                            inferenceDurationNanos: UInt64(duration * 1_000_000_000),
                            warnings: warnings,
                            fallbackReason: raw.isEmpty ? "no final decode; partial used" : nil,
                            termination: .completed)
    }

    private func engineIdentity() -> EngineIdentity {
        EngineIdentity(kind: .whisper, modelName: modelName,
                       modelVersion: nil, modelDigest: nil)
    }

    func cancel() async {
        isFinalizing = true
        partialLoopTask?.cancel()
        partialLoopTask = nil
        await waitForDecodeIdle()
        cleanup()
    }

    // MARK: - Single-flight decode

    /// JOE-2250: exclusive gate around every WhisperKit `transcribe` call.
    /// Finalization waits for the owned partial to END (finish) — it never
    /// starts a second decode after a polling cap, and a deadline retains
    /// ownership until the native call actually ends.
    private func runTranscribe(
        kit: WhisperKit,
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
        let op = decodeOwnership.begin(purpose: purpose,
                                       sessionID: sessionID,
                                       nowNanos: now)
        guard let op else {
            throw WhisperEngineError.decodeBusy
        }
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            _ = decodeOwnership.finish(op, outcome: .completed)
            return results.map(\.text).joined(separator: " ")
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
            let text = try await runTranscribe(kit: kit, samples: slice,
                                                options: partialDecodeOptions(language: currentLanguage),
                                                purpose: .partial)
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
        decodeOwnership = DecodeOwnership()
        currentDecodeSessionID = nil
        lastPartialText = ""
        startTime = nil
    }
}
