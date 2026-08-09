import Foundation
import ZephyrFlowCore

// JOE-2244: production implementation of the per-session stage provider.
// One instance per session — owns the session-scoped audio channel, delivery
// task, accounting, drain barrier, callback gate and engine binding. The
// DictationSession actor owns sequencing; this type only performs leaf I/O.
final class ProductionSessionStages: DictationSessionStageProviding, @unchecked Sendable {
    private let environment: AppEnvironment
    private let engine: any WhisperEngineProtocol
    private let engineKind: SessionEngineChoice
    private let engineToken: EngineToken
    private let audio = AudioCapture.shared
    private let settingsStore = SettingsStore.shared
    private let lock = NSLock()

    // Session-scoped mutable state (fresh instance per session).
    private var channel: BoundedAudioChannel?
    private var sequencer = AudioChunkSequencer()
    private var converter: SessionAudioConverter?
    private var deliveryTask: Task<Void, Never>?
    private var accounting = AudioFrameAccounting()
    private var drainBarrier = AudioDrainBarrier(deadlineNanosAhead: 3_000_000_000)
    private var callbackGate = CallbackGate()
    private var binding: SessionEngineBinding?
    private var interimContinuation: AsyncStream<SessionPartial>.Continuation?
    private var levelsContinuation: AsyncStream<Float>.Continuation?
    private var levelsPollTask: Task<Void, Never>?
    private var targetSnapshot: TargetSnapshot?
    private var effectiveSensitivity: SessionSensitivity = .unknown

    init(
        environment: AppEnvironment,
        engine: any WhisperEngineProtocol,
        engineKind: SessionEngineChoice,
        engineToken: EngineToken = EngineToken()
    ) {
        self.environment = environment
        self.engine = engine
        self.engineKind = engineKind
        self.engineToken = engineToken
    }

    // MARK: - DictationSessionStageProviding

    // MARK: - Session preparation (JOE-2244)

    func prepare(sessionID: SessionID) async {
        // Immutable session-owned binding + fresh gate (JOE-2249).
        self.binding = SessionEngineBinding(
            sessionID: sessionID,
            engineToken: engineToken,
            engineKind: engineKind == .appleSpeech ? .appleSpeech : .whisper)
        self.callbackGate = CallbackGate()
        // JOE-2268: capture the immutable target snapshot (AX evidence).
        // Missing AX permission => nil => session stays .unknown (fail closed).
        self.targetSnapshot = environment.targetValidation.captureSnapshot(
            sessionID: sessionID,
            nowNanos: environment.clock.nowNanos())
    }

    func capturedTargetSnapshot() async -> TargetSnapshot? {
        targetSnapshot
    }

    func startCapture(
        sessionID: SessionID, localOnly: Bool,
        language: SupportedLanguage
    ) async throws -> SessionCaptureHandle {
        let interim = AsyncStream<SessionPartial> { self.interimContinuation = $0 }
        let levels = AsyncStream<Float> { self.levelsContinuation = $0 }

        try await engine.startStreaming(
            sessionID: sessionID,
            localOnly: localOnly,
            language: language
        ) { [weak self] partial in
            guard let self,
                let binding = self.binding,
                self.callbackGate.accepts(
                    binding: binding,
                    currentSessionID: sessionID,
                    currentEngineToken: self.engineToken)
            else { return }
            self.interimContinuation?.yield(SessionPartial(text: partial.text))
        }

        if engineKind == .whisper {
            // Bounded, ordered audio channel (JOE-2247): capacity 256 chunks.
            let channel = BoundedAudioChannel(sessionID: sessionID, capacity: 256)
            self.channel = channel
            self.sequencer = AudioChunkSequencer()
            self.converter = SessionAudioConverter()
            let engine = self.engine
            self.deliveryTask = Task { [weak self] in
                guard let self, let converter = self.converter else { return }
                for await chunk in channel.chunks {
                    self.accounting.noteCaptured(
                        sourceSamples: UInt64(chunk.samples.count),
                        sourceRate: chunk.sampleRate)
                    if chunk.sequence < self.sequencer.nextExpected {
                        self.accounting.noteDropped(sourceSamples: UInt64(chunk.samples.count), reason: .lateAppend)
                        continue
                    }
                    self.sequencer.accept(chunk)
                    guard let mono = converter.convert(chunk) else {
                        self.accounting.noteDropped(
                            sourceSamples: UInt64(chunk.samples.count), reason: .converterFailure)
                        continue
                    }
                    self.accounting.noteConverted(engineSamples: UInt64(mono.count))
                    await engine.appendAudio(mono)
                    self.accounting.noteDelivered(engineSamples: UInt64(mono.count))
                    _ = self.drainBarrier.noteDelivered(
                        sequence: chunk.sequence,
                        nowNanos: self.environment.clock.nowNanos())
                }
            }
            try await audio.start(sessionID: sessionID, channel: channel)
        }

        // Levels polling (content-free). Apple engine exposes levels
        // directly; Whisper path samples the capture tap.
        let audio = self.audio
        let appleEngine: AppleSpeechEngine? =
            self.engineKind == .appleSpeech
            ? (self.engine as? AppleSpeechEngine) : nil
        self.levelsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let levels: [Float]
                if let appleEngine {
                    levels = await appleEngine.levels()
                } else {
                    levels = await audio.levels()
                }
                if let peak = levels.max(), peak > 0.08 {
                    self.levelsContinuation?.yield(peak)
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        return SessionCaptureHandle(interim: interim, levels: levels)
    }

    func stopCapture() async -> SessionAudioSummary {
        await audio.stop()
        guard engineKind == .whisper else {
            // Apple path: no bounded channel; no frame accounting.
            return SessionAudioSummary(
                capturedSourceSamples: 0,
                deliveredEngineSamples: 0,
                droppedSamples: 0,
                degraded: false,
                reconciled: true,
                drainState: "n/a")
        }
        // JOE-2248: end-of-stream drain barrier at the final accepted
        // producer sequence; the delivery task drains through it.
        var channel = self.channel
        if let finalSeq = channel?.stats().lastAcceptedSequence {
            drainBarrier.begin(
                finalSequence: finalSeq,
                nowNanos: environment.clock.nowNanos())
        }
        await deliveryTask?.value
        let channelStats = channel?.stats()
        let seqDegraded = sequencer.isDegraded
        let channelDegraded = channel?.isDegraded ?? false
        let barrierTimedOut = drainBarrier.state == .timedOut
        let lateAppends = drainBarrier.lateAppends
        if let channelStats {
            if channelStats.overflowDropped > 0 {
                accounting.noteDropped(sourceSamples: channelStats.overflowDroppedSamples, reason: .overflow)
            }
            if channelStats.wrongSessionRejected > 0 {
                accounting.noteDropped(sourceSamples: channelStats.wrongSessionDroppedSamples, reason: .wrongSession)
            }
            if channelStats.closedDropped > 0 {
                accounting.noteDropped(sourceSamples: channelStats.closedDroppedSamples, reason: .closedDrop)
            }
        }
        let ratio = SessionAudioConverter.targetSampleRate / accounting.sourceSampleRate
        let reconciled = accounting.reconciles(
            converterRatio: ratio,
            roundingToleranceSamples: 64)
        let degraded = seqDegraded || channelDegraded || barrierTimedOut || lateAppends > 0 || !reconciled
        let summary = SessionAudioSummary(
            capturedSourceSamples: accounting.capturedSourceSamples,
            deliveredEngineSamples: accounting.deliveredEngineSamples,
            droppedSamples: accounting.droppedSourceSamples,
            degraded: degraded,
            reconciled: reconciled,
            drainState: drainBarrier.state.rawValue)
        deliveryTask = nil
        channel = nil
        converter = nil
        return summary
    }

    func finalize() async throws -> EngineResult {
        try await engine.stopAndFinalize()
    }

    func applyFlow(_ request: FlowRequest) async -> FlowOutcome {
        await environment.flow.process(request)
    }

    func validateTarget() async -> SessionValidationResult {
        guard let snapshot = targetSnapshot else {
            return SessionValidationResult(
                outcome: .targetUnknown,
                effectiveSensitivity: .unknown)
        }
        var validation = TargetValidationSession(
            sessionID: snapshot.sessionID,
            snapshot: snapshot,
            deadlineNanosAhead: 2_000_000_000)
        validation.start(nowNanos: environment.clock.nowNanos())
        // Bounded, observable restore (never a blind sleep).
        let monitor = await environment.targetValidation.restoreToCapturedTarget(
            snapshot: snapshot, deadlineNanosAhead: 2_000_000_000)
        let context = environment.targetValidation.currentContext(
            nowNanos: environment.clock.nowNanos())
        let outcome = validation.validate(
            context: context,
            nowNanos: environment.clock.nowNanos())
        effectiveSensitivity = validation.effectiveSensitivity
        return SessionValidationResult(
            outcome: outcome,
            effectiveSensitivity: validation.effectiveSensitivity)
    }

    func insert(_ request: SessionInsertRequest) async -> InsertionOutcome {
        await environment.insertion.insert(
            request.text,
            preferPaste: request.preferPaste,
            mode: InsertionMode(rawValue: request.insertionMode) ?? .automatic,
            targetBundleID: request.targetBundleID,
            sensitivity: request.sensitivity,
            sessionID: request.sessionID,
            copyOnlyOverrides: request.copyOnlyOverrides)
    }

    func recordHistory(
        originalText: String, finalText: String,
        duration: TimeInterval, modelName: String
    ) async {
        await environment.history.add(
            HistoryEntry(
                originalText: originalText,
                finalText: finalText,
                duration: duration,
                modelUsed: modelName))
    }

    func cancel() async {
        levelsPollTask?.cancel()
        levelsPollTask = nil
        interimContinuation?.finish()
        levelsContinuation?.finish()
        interimContinuation = nil
        levelsContinuation = nil
        await audio.stop()
        channel?.close()
        channel = nil
        await engine.cancel()
        callbackGate.close(reason: .terminalOutcome)
        binding = nil
    }
}
