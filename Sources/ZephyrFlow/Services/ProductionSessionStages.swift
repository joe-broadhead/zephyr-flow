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
    /// Review R1.3 (v2): set (under the lock) when the delivery task's
    /// consumer loop exits. stopCapture races this against the deadline —
    /// unlike Task.isCancelled, a normally-completed task DOES set it.
    private var deliveryFinished = false
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
            self.deliveryFinished = false
            self.deliveryTask = Task { [weak self] in
                guard let self, let converter = self.converter else { return }
                defer {
                    // Review R1.3 (v2): mark completion under the lock so
                    // stopCapture can wait on a real completion signal. The
                    // EOS converter flush + tail append happen in the post-loop
                    // block BELOW (awaited) BEFORE this defer runs.
                    self.lock.withLock { self.deliveryFinished = true }
                }
                for await chunk in channel.chunks {
                    self.lock.lock()
                    self.accounting.noteCaptured(
                        sourceSamples: UInt64(chunk.samples.count),
                        sourceRate: chunk.sampleRate)
                    if chunk.sequence < self.sequencer.nextExpected {
                        self.accounting.noteDropped(sourceSamples: UInt64(chunk.samples.count), reason: .lateAppend)
                        self.lock.unlock()
                        continue
                    }
                    self.sequencer.accept(chunk)
                    self.lock.unlock()
                    guard let mono = converter.convert(chunk) else {
                        self.lock.lock()
                        self.accounting.noteDropped(
                            sourceSamples: UInt64(chunk.samples.count), reason: .converterFailure)
                        self.lock.unlock()
                        continue
                    }
                    await engine.appendAudio(mono)
                    self.lock.lock()
                    self.accounting.noteConverted(engineSamples: UInt64(mono.count))
                    self.accounting.noteDelivered(engineSamples: UInt64(mono.count))
                    let now = self.environment.clock.nowNanos()
                    _ = self.drainBarrier.noteDelivered(
                        sequence: chunk.sequence,
                        nowNanos: now)
                    self.lock.unlock()
                }
                // Review B1v2: flush the converter's EOS tail INSIDE the
                // consumer (after the loop, before completion), append it to
                // the engine, and account it — then the defer sets
                // deliveryFinished. This guarantees the tail is never omitted
                // by a scheduling window where the barrier drained but the
                // consumer had not finished.
                if let tail = converter.flush(), !tail.isEmpty {
                    await engine.appendAudio(tail)
                    self.lock.withLock {
                        self.accounting.noteConverted(engineSamples: UInt64(tail.count))
                        self.accounting.noteDelivered(engineSamples: UInt64(tail.count))
                    }
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
        // Review B1: atomic producer shutdown. FIRST close the channel (the
        // producer's enqueue returns .closed for anything after — counted, not
        // lost), THEN snapshot the immutable final accepted sequence, THEN arm
        // the barrier. The barrier tracks highest-delivered-while-idle, so a
        // final sequence already delivered before arming drains immediately.
        // No tap callback can enqueue between snapshot and stop because the
        // channel is already closed when we snapshot.
        let channel = self.channel
        await audio.stop()  // closes the channel (ends producer admission)
        let acceptedSamples = channel?.stats().acceptedSamples ?? 0
        if let finalSeq = channel?.stats().lastAcceptedSequence {
            lock.withLock {
                drainBarrier.begin(
                    finalSequence: finalSeq,
                    nowNanos: environment.clock.nowNanos())
            }
        }

        // Bounded wait for the consumer using a REAL completion signal:
        // the delivery task sets deliveryFinished when its loop exits. We race
        // barrier-terminal AND delivery-finished against the deadline. (The old
        // `while !delivery.isCancelled` never saw a normally-completed task.)
        // Review B1v2: SUCCESS requires BOTH the barrier drained AND the
        // consumer task COMPLETED (the converter flush happens inside the
        // consumer's defer before deliveryFinished). Wait for deliveryFinished
        // (bounded); if the consumer never completes, degrade.
        let drainDeadlineNanos = drainBarrier.deadlineNanosAhead + 1_000_000_000
        let waitStart = environment.clock.nowNanos()
        while true {
            let finished = lock.withLock { deliveryFinished }
            if finished { break }
            if environment.clock.nowNanos() &- waitStart >= drainDeadlineNanos {
                lock.withLock { drainBarrier.markTimedOut() }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // If the consumer still hasn't completed at the deadline, it may be
        // suspended in engine.appendAudio and could mutate accounting later.
        // We do NOT await it further (bounded); the barrier is timedOut so the
        // summary degrades, and we retain the task handle (no discard that
        // lets it mutate unseen state after we read it).
        if !(lock.withLock { deliveryFinished }) {
            ZFLog.info("Audio consumer did not complete in time — degraded")
        }
        let channelStats = channel?.stats()
        _ = channelStats
        let (seqDegraded, barrierTimedOut, barrierDrained, lateAppends) = lock.withLock {
            (
                sequencer.isDegraded,
                drainBarrier.state == .timedOut,
                drainBarrier.state == .drained,
                drainBarrier.lateAppends
            )
        }
        let channelDegraded = channel?.isDegraded ?? false
        if let channelStats {
            lock.withLock {
                if channelStats.overflowDropped > 0 {
                    accounting.noteDropped(sourceSamples: channelStats.overflowDroppedSamples, reason: .overflow)
                }
                if channelStats.wrongSessionRejected > 0 {
                    accounting.noteDropped(
                        sourceSamples: channelStats.wrongSessionDroppedSamples, reason: .wrongSession)
                }
                if channelStats.closedDropped > 0 {
                    accounting.noteDropped(sourceSamples: channelStats.closedDroppedSamples, reason: .closedDrop)
                }
            }
        }
        // Review B1: reconcile against the channel's ACCEPTED sample count
        // (authoritative admission), not only the samples the consumer
        // dequeued — accepted-but-not-yet-delivered chunks must be counted.
        let expectedCaptured = max(acceptedSamples, accounting.capturedSourceSamples)
        let ratio = SessionAudioConverter.targetSampleRate / accounting.sourceSampleRate
        let reconciled = accounting.reconciles(
            converterRatio: ratio,
            roundingToleranceSamples: 64,
            expectedCapturedSourceSamples: expectedCaptured)
        // Review R1.3: a successful capture requires the barrier to have
        // DRAINED (final sequence acknowledged). A barrier left .draining is
        // degraded — it never acknowledged the end-of-stream marker.
        let notDrained = !barrierDrained
        let degraded = seqDegraded || channelDegraded || barrierTimedOut || notDrained || lateAppends > 0 || !reconciled
        let summary = SessionAudioSummary(
            capturedSourceSamples: accounting.capturedSourceSamples,
            deliveredEngineSamples: accounting.deliveredEngineSamples,
            droppedSamples: accounting.droppedSourceSamples,
            degraded: degraded,
            reconciled: reconciled,
            drainState: drainBarrier.state.rawValue)
        deliveryTask = nil
        converter = nil
        // Note: `channel` is a local copy (let) from self.channel; the shared
        // self.channel is cleared in cancel()/deinit. No local clear needed.
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
            copyOnlyOverrides: request.copyOnlyOverrides,
            // Review B4: pass the validated element identity so the AX write
            // binds to the exact validated target.
            validatedElement: request.validatedElement,
            validatedPid: request.validatedPid,
            validatedWindowID: request.validatedWindowID)
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
