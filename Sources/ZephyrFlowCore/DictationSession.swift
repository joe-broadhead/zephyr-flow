import Foundation

// JOE-2244: session truth, resource ownership and stage orchestration live in
// ONE isolated per-session actor. The UI coordinator is a thin MainActor
// projection that only creates sessions and maps typed UI states.

// MARK: - Typed read-only UI state

public enum SessionPhase: String, Sendable, Equatable {
    case idle
    case listening
    case processing
    case success
    case warning
    case review
    case error
    case hidden
}

/// Content-free audio summary (counts and controlled reasons only).
public struct SessionAudioSummary: Sendable, Equatable {
    public let capturedSourceSamples: UInt64
    public let deliveredEngineSamples: UInt64
    public let droppedSamples: UInt64
    public let degraded: Bool
    public let reconciled: Bool
    public let drainState: String

    public init(
        capturedSourceSamples: UInt64,
        deliveredEngineSamples: UInt64,
        droppedSamples: UInt64,
        degraded: Bool,
        reconciled: Bool,
        drainState: String
    ) {
        self.capturedSourceSamples = capturedSourceSamples
        self.deliveredEngineSamples = deliveredEngineSamples
        self.droppedSamples = droppedSamples
        self.degraded = degraded
        self.reconciled = reconciled
        self.drainState = drainState
    }
}

/// Explicit stage outputs — every business stage produces a typed value.
public struct SessionStageOutputs: Sendable, Equatable {
    public var audioSummary: SessionAudioSummary?
    public var engineResult: EngineResult?
    public var flowOutcome: FlowOutcome?
    public var validation: TargetValidationOutcome?
    public var insertion: InsertionOutcome?

    public init(
        audioSummary: SessionAudioSummary? = nil,
        engineResult: EngineResult? = nil,
        flowOutcome: FlowOutcome? = nil,
        validation: TargetValidationOutcome? = nil,
        insertion: InsertionOutcome? = nil
    ) {
        self.audioSummary = audioSummary
        self.engineResult = engineResult
        self.flowOutcome = flowOutcome
        self.validation = validation
        self.insertion = insertion
    }
}

/// Read-only UI projection state. Interim text is a LENGTH only — transcript
/// bodies never cross into Core telemetry/UI-state logs.
public struct SessionUIState: Sendable, Equatable {
    public var phase: SessionPhase
    /// Transcript body for UI display only (never logged; tests assert
    /// lengths/equality).
    public var interimText: String
    public var interimLength: Int
    public var audioLevel: Float
    public var outputs: SessionStageOutputs

    public init(
        phase: SessionPhase = .idle,
        interimText: String = "",
        interimLength: Int = 0,
        audioLevel: Float = 0.05,
        outputs: SessionStageOutputs = SessionStageOutputs()
    ) {
        self.phase = phase
        self.interimText = interimText
        self.interimLength = interimLength
        self.audioLevel = audioLevel
        self.outputs = outputs
    }
}

// MARK: - Multicast state broadcaster (UI subscribers may reconnect)

/// Replay-latest multicast stream: a subscriber always receives the current
/// state immediately, then live updates. Reconnecting does NOT change session
/// state.
public final class SessionStateBroadcaster<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: State
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(initial: State) { self.current = initial }

    public func publish(_ state: State) {
        lock.lock()
        current = state
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(state) }
    }

    public func subscribe() -> AsyncStream<State> {
        lock.lock()
        let snapshot = current
        lock.unlock()
        let id = UUID()
        return AsyncStream { continuation in
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
            continuation.yield(snapshot)
        }
    }

    public func finish() {
        lock.lock()
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}

// MARK: - Immutable session inputs (engine choice / settings snapshot)

public enum SessionEngineChoice: String, Sendable, Equatable {
    case appleSpeech
    case whisper
}

public struct SessionSettingsSnapshot: Sendable, Equatable {
    public let localOnly: Bool
    public let language: SupportedLanguage
    public let defaultFlowStyle: FlowStyle
    public let insertionMode: String
    public let saveHistory: Bool
    public let copyOnlyOverrideBundleIDs: [String]

    public init(
        localOnly: Bool,
        language: SupportedLanguage,
        defaultFlowStyle: FlowStyle,
        insertionMode: String,
        saveHistory: Bool,
        copyOnlyOverrideBundleIDs: [String]
    ) {
        self.localOnly = localOnly
        self.language = language
        self.defaultFlowStyle = defaultFlowStyle
        self.insertionMode = insertionMode
        self.saveHistory = saveHistory
        self.copyOnlyOverrideBundleIDs = copyOnlyOverrideBundleIDs
    }
}

// MARK: - Insertion request

public struct SessionInsertRequest: Sendable, Equatable {
    public let text: String
    public let preferPaste: Bool
    public let insertionMode: String
    public let targetBundleID: String?
    /// Review B4: the element identity that was VALIDATED. Insertion must only
    /// mutate this exact element; a re-resolved element that differs (same
    /// app, different field/window) fails closed instead of inserting.
    public let validatedElement: TargetSnapshot.ElementIdentity?
    public let validatedPid: Int32?
    public let validatedWindowID: UInt32?
    /// Round-5 B4: the complete, immutable one-use target lease produced by
    /// successful validation. The paste path validates the WHOLE lease
    /// (PID + process-start + bundle + window + element + capabilities)
    /// before clipboard mutation and again immediately before Command-V.
    public let lease: TargetLease?
    public let sensitivity: SessionSensitivity
    public let sessionID: SessionID
    public let copyOnlyOverrides: Set<String>

    public init(
        text: String, preferPaste: Bool, insertionMode: String,
        targetBundleID: String?,
        validatedElement: TargetSnapshot.ElementIdentity? = nil,
        validatedPid: Int32? = nil,
        validatedWindowID: UInt32? = nil,
        lease: TargetLease? = nil,
        sensitivity: SessionSensitivity,
        sessionID: SessionID, copyOnlyOverrides: Set<String>
    ) {
        self.text = text
        self.preferPaste = preferPaste
        self.insertionMode = insertionMode
        self.targetBundleID = targetBundleID
        self.validatedElement = validatedElement
        self.validatedPid = validatedPid
        self.validatedWindowID = validatedWindowID
        self.lease = lease
        self.sensitivity = sensitivity
        self.sessionID = sessionID
        self.copyOnlyOverrides = copyOnlyOverrides
    }
}

/// Typed validation result: the controlled outcome plus the effective
/// (most-restrictive) sensitivity resolved at validation time.
public struct SessionValidationResult: Sendable, Equatable {
    public let outcome: TargetValidationOutcome
    public let effectiveSensitivity: SessionSensitivity

    public init(
        outcome: TargetValidationOutcome,
        effectiveSensitivity: SessionSensitivity
    ) {
        self.outcome = outcome
        self.effectiveSensitivity = effectiveSensitivity
    }
}

// MARK: - Stage provider (leaf operations; app layer implements with real
// services, tests inject fakes). Sequencing/ownership stays in the actor.

/// Interim partial from the engine (text body stays in the app layer and
/// is NEVER logged; the actor publishes only its length).
public struct SessionPartial: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct SessionCaptureHandle: Sendable {
    public let interim: AsyncStream<SessionPartial>
    public let levels: AsyncStream<Float>

    public init(
        interim: AsyncStream<SessionPartial>,
        levels: AsyncStream<Float>
    ) {
        self.interim = interim
        self.levels = levels
    }
}

public protocol DictationSessionStageProviding: Sendable {
    /// Prepare the session-scoped resources (AX target snapshot capture,
    /// engine binding) — called by the actor after SessionID allocation and
    /// before any capture.
    func prepare(sessionID: SessionID) async
    /// The AX target snapshot captured during prepare (nil = fail closed).
    func capturedTargetSnapshot() async -> TargetSnapshot?
    /// Begin capture + engine streaming. Returns interim/level streams.
    func startCapture(
        sessionID: SessionID, localOnly: Bool,
        language: SupportedLanguage
    ) async throws -> SessionCaptureHandle
    /// Stop the microphone, drain the ordered channel; returns counts only.
    func stopCapture() async -> SessionAudioSummary
    /// Finalize engine decode -> explicit engine result.
    func finalize() async throws -> EngineResult
    /// Apply Flow rules -> explicit Flow outcome.
    func applyFlow(_ request: FlowRequest) async -> FlowOutcome
    /// Restore + revalidate the captured target -> typed outcome +
    /// effective sensitivity.
    func validateTarget() async -> SessionValidationResult
    /// Persist history (transcript-bearing mutation; policy decided by the
    /// actor, I/O performed by the provider).
    func recordHistory(
        originalText: String, finalText: String,
        duration: TimeInterval, modelName: String) async
    /// Insert the final text -> explicit insertion outcome.
    func insert(_ request: SessionInsertRequest) async -> InsertionOutcome
    /// Cancel engine + capture immediately (idempotent).
    func cancel() async
}

// MARK: - Shared session identity (JOE-2244)

/// Lock-protected monotonic SessionID source shared across sessions so two
/// successive sessions can never collide on identity (tasks, buffers, target
/// identity and callbacks are keyed by SessionID).
public final class SessionIDFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    public init() {}

    public func next(createdAtNanos: UInt64) -> SessionID {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return SessionID(
            token: "zf", sequence: sequence,
            createdAtUptimeNanos: createdAtNanos)
    }
}

// MARK: - DictationSession actor (session truth + stage orchestration)

/// One isolated actor per session. Owns the control plane, generation,
/// stage sequencing, typed outputs and exactly-once terminal release.
/// The MainActor coordinator only creates sessions and maps `SessionUIState`.
public actor DictationSession {
    public enum Command: Sendable, Equatable {
        case end
        case cancel
        /// User-initiated retry from a review phase: re-validate the original
        /// captured target and re-insert the retained final text.
        case retry
        /// User dismissed the review panel: finish without side effects.
        case discard
    }

    /// Immutable identity allocated BEFORE any asynchronous preparation.
    public let sessionID: SessionID
    public let engineChoice: SessionEngineChoice
    public let settings: SessionSettingsSnapshot
    /// AX target evidence captured by the provider during `prepare`
    /// (nil when AX untrusted -> fail-closed review-only).
    public private(set) var targetSnapshot: TargetSnapshot?

    private let provider: any DictationSessionStageProviding
    private let nowNanos: @Sendable () -> UInt64
    private var control = SessionControlModel()
    private let idFactory: SessionIDFactory
    private var broadcaster: SessionStateBroadcaster<SessionUIState>
    private var commandContinuation: AsyncStream<Command>.Continuation?
    /// The single command stream for the whole session (capture wait AND
    /// review phases consume it, so buffered follow-ups are never lost).
    private var commandStream: AsyncStream<Command>?
    private var captureTask: Task<Void, Never>?
    private var levelsTask: Task<Void, Never>?
    private var state = SessionUIState()
    private var startTime: UInt64?
    private var retainedText = ""
    private var released = false
    /// Review R2/4: set when cancel() is called, so cancellation is observed
    /// at every stage even without an active command consumer.
    private var cancelRequested = false
    /// Review B3: exactly-one terminal emission via TerminalGuard + sink.
    private var terminalGuard: TerminalGuard
    /// Round-5 B3: ONE stored telemetry ID for every event in this session
    /// (terminal + capture-accounting), so records can be correlated.
    private let sessionTelemetryID: SessionTelemetryID
    private let telemetrySink = BoundedEventSink(capacity: 64)
    /// Review B2v2 (round 5): release signal — fired exactly once in
    /// finishTerminal after `released = true`. Lets the host (controller)
    /// join session termination with a bounded deadline instead of claiming
    /// cleanup before the run() task has reached terminal release.
    private var releaseContinuation: AsyncStream<Void>.Continuation?
    private var releaseStream: AsyncStream<Void>?

    public init(
        provider: any DictationSessionStageProviding,
        engineChoice: SessionEngineChoice,
        settings: SessionSettingsSnapshot,
        idFactory: SessionIDFactory = SessionIDFactory(),
        nowNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.provider = provider
        self.engineChoice = engineChoice
        self.settings = settings
        self.idFactory = idFactory
        self.nowNanos = nowNanos
        var control = SessionControlModel()
        let sid = idFactory.next(createdAtNanos: nowNanos())
        guard control.begin(sessionID: sid) != nil else {
            preconditionFailure("DictationSession: control plane rejected admission")
        }
        self.control = control
        self.sessionID = sid
        self.broadcaster = SessionStateBroadcaster<SessionUIState>(initial: SessionUIState())
        // Review B3v2: unique telemetry id per session (not token, which is
        // 'zf' for every session). Round-5 B3: stored once and reused by
        // capture-accounting events so they correlate with the terminal.
        let tid = SessionTelemetryID()
        self.sessionTelemetryID = tid
        self.terminalGuard = TerminalGuard(sessionID: tid)
        // Review R2/4: create a DURABLE command mailbox at init so control
        // events (end/cancel/retry/discard) are never lost before run()
        // installs the consumer. Buffering keeps commands sent during setup
        // and processing stages; the consumer drains them in order.
        var cont: AsyncStream<Command>.Continuation?
        let stream = AsyncStream<Command>(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        self.commandContinuation = cont
        self.commandStream = stream
        var relCont: AsyncStream<Void>.Continuation?
        let relStream = AsyncStream<Void> { relCont = $0 }
        self.releaseContinuation = relCont
        self.releaseStream = relStream
    }

    // MARK: - Termination join (round-5 B2)

    /// Review B2v2 (round 5): bounded join on session termination. Returns
    /// true when the session reached exactly-once terminal release before the
    /// deadline; false when it is still running (the caller must treat the
    /// session as not-quiesced and never claim cleanup).
    public func awaitTerminalAndReleased(
        deadlineNanosAhead: UInt64 = 3_000_000_000
    ) async -> Bool {
        // Already released: immediate success.
        if released { return true }
        guard let releaseStream else { return false }
        // Race the release signal against a bounded deadline. The release
        // task returns true when finishTerminal yields; the sleep task
        // returns false at the deadline — first result wins, then the group
        // is cancelled so neither side outlives the call.
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = releaseStream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNanosAhead)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - UI subscription (reconnect-safe)

    public func subscribe() -> AsyncStream<SessionUIState> {
        broadcaster.subscribe()
    }

    /// Review B3: drain the emitted terminal telemetry (host reads once).
    public func drainTelemetry() -> [TelemetryEvent] {
        telemetrySink.drain()
    }

    // MARK: - Control events (hotkey/app path)

    public func end() {
        commandContinuation?.yield(.end)
    }

    public func cancel() async {
        // Review B2v2: set the durable flag AND actively invoke the provider's
        // cancel so an in-flight finalize/streaming is interrupted, not merely
        // flagged for a later stage boundary. Also yield to the stream for
        // review-phase command handling.
        cancelRequested = true
        await provider.cancel()
        commandContinuation?.yield(.cancel)
    }

    /// Retry insertion of the retained final text (review phase only).
    public func retryInsertion() {
        commandContinuation?.yield(.retry)
    }

    /// Dismiss the review panel (no side effects).
    public func discard() {
        commandContinuation?.yield(.discard)
    }

    // MARK: - Orchestration

    public func run() async {
        guard !released else { return }
        startTime = nowNanos()
        publish(phase: .listening, interim: "", level: 0.05)

        guard let commands = commandStream else { return }
        // commandStream was created at init (durable mailbox); the consumer
        // drains buffered control events in order.

        // Review B2v2: a cancel buffered before/at start must prevent
        // preparation and microphone activation, not just be observed later.
        if await checkCancellation() { return }

        // Session-scoped preparation: AX target snapshot + engine binding.
        await provider.prepare(sessionID: sessionID)
        targetSnapshot = await provider.capturedTargetSnapshot()

        // Review B2v2: cancel during preparation must prevent capture start.
        if await checkCancellation() { return }

        // Stage 1: capture + engine streaming starts immediately (begin edge).
        let handle: SessionCaptureHandle
        do {
            handle = try await provider.startCapture(
                sessionID: sessionID,
                localOnly: settings.localOnly,
                language: settings.language)
        } catch {
            _ = control.stage(.captureFailed)
            // Review R2/6: release any partially-acquired engine/audio
            // resources so the next session can start cleanly.
            await provider.cancel()
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        // Review R1.5: the state machine was left in .preparing because the
        // capture-started transition was never staged. Drive it to
        // .capturing now that the capture is live.
        if control.stage(.readyToCapture).isRejected {
            await provider.cancel()
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await partial in handle.interim {
                await self.publish(phase: .listening, interim: partial.text, level: self.state.audioLevel)
            }
        }
        levelsTask = Task { [weak self] in
            guard let self else { return }
            for await level in handle.levels {
                await self.publish(phase: self.state.phase, interim: self.state.interimText, level: level)
            }
        }

        // Wait for the release edge (end/cancel) — the ONLY way out of
        // capture. The first command is consumed HERE, after capture starts.
        var command: Command?
        for await c in commands {
            command = c
            break
        }
        guard let command else { return }

        if command == .cancel {
            await provider.cancel()
            _ = control.cancel()
            publish(phase: .hidden, interim: "", level: 0.05)
            finishTerminal(category: .cancelled)
            return
        }

        // Stage 2: the release edge (end) drives the state machine from
        // .capturing to .draining BEFORE stopCapture; drainFinished then
        // legally advances to .transcribing (review R1.5).
        if control.stage(.stop).isRejected {
            await provider.cancel()
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        // Review R2/4: a cancel during capture must preempt the stop/insert.
        if await checkCancellation() { return }
        // Stage 2: stop capture + drain -> audio summary (counts only).
        captureTask?.cancel()
        levelsTask?.cancel()
        let audioSummary = await provider.stopCapture()
        state.outputs.audioSummary = audioSummary
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        if audioSummary.degraded || !audioSummary.reconciled {
            // Round-5 B3: degraded is a DRAIN-stage failure — stage the legal
            // .drainFailed event (from .draining), not the illegal
            // .captureFailed (which is only legal from .capturing).
            _ = control.stage(.drainFailed)
            // Review R2/6: a degraded capture must release the engine (a
            // streaming engine would block the NEXT session with
            // alreadyStreaming). cancel() stops audio + engine + channel.
            await provider.cancel()
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .degraded)
            return
        }

        // Review R2/4: cancel before final decode.
        if await checkCancellation() { return }
        // Stage 3: finalize decode -> explicit engine result.
        // Review B3: stage transitions must FOLLOW the work they describe.
        // drainFinished -> finalize -> transcriptionFinished (only after the
        // engine result exists). Staging transcriptionFinished before
        // finalize moved the state to .transforming while the engine was
        // still transcribing; a finalize failure then attempted
        // .captureFailed from the wrong state.
        if control.stage(.drainFinished).isRejected {
            await provider.cancel()
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        let final: EngineResult
        do {
            final = try await provider.finalize()
        } catch {
            // Round-5 B3: finalize failure occurs in .transcribing — the legal
            // event is .transcriptionFailed (not .captureFailed, which is only
            // legal from .capturing).
            _ = control.stage(.transcriptionFailed)
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        state.outputs.engineResult = final
        // Transcription actually finished (finalize returned): stage it now.
        if control.stage(.transcriptionFinished).isRejected {
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        if final.completeness != .complete {
            // Round-5 B3: an incomplete engine result occurs in .transforming —
            // stage the legal .engineTruncated/.enginePartial terminal, not
            // .targetUnknown (which belongs to target resolution).
            switch final.completeness {
            case .partial:
                _ = control.stage(.enginePartial)
            case .truncated:
                _ = control.stage(.engineTruncated)
            default:
                _ = control.stage(.engineTruncated)
            }
            publish(phase: .warning, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: final.completeness == .partial ? .partial : .truncated)
            return
        }

        // Stage 4: Flow — secure/unknown sessions never run structural Flow
        // and never auto-insert (fail-closed review-only, JOE-2259).
        if !sessionAllowsAutomaticSideEffects {
            // Review R2/4: cancel before the sensitive review/Flow path.
            if await checkCancellation() { return }
            // Review B3: stage transformationFinished AFTER applyFlow runs.
            let conservative = await provider.applyFlow(
                FlowRequest(
                    sessionID: sessionID, text: final.text, style: .clean,
                    language: settings.language,
                    sensitivity: targetSnapshot?.sensitivity.sensitivity ?? .unknown))
            _ = control.stage(.transformationFinished)
            state.outputs.flowOutcome = conservative
            let reviewText = conservative.text.trimmingCharacters(in: .whitespacesAndNewlines)
            retainedText = reviewText
            publish(phase: .review, interim: reviewText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: true)
            return
        }

        // Review R2/4: cancel before Flow transformation.
        if await checkCancellation() { return }
        let flowOutcome = await provider.applyFlow(
            FlowRequest(
                sessionID: sessionID, text: final.text, style: settings.defaultFlowStyle,
                language: settings.language,
                sensitivity: targetSnapshot?.sensitivity.sensitivity ?? .unknown))
        // Review B3: stage transformationFinished AFTER applyFlow returns.
        if control.stage(.transformationFinished).isRejected {
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        state.outputs.flowOutcome = flowOutcome
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        // Review B5: a rejected Flow outcome (protected spans not preserved)
        // must NEVER be automatically inserted. The outcome's text is the
        // original input (conservative fallback), but automatic insertion is
        // disabled — surface the review surface so the user decides.
        if flowOutcome.status == .rejected {
            publish(phase: .review, interim: flowOutcome.text, level: state.audioLevel)
            retainedText = flowOutcome.text
            await handleReviewCommands(secureOnly: false)
            return
        }
        let trimmed = flowOutcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        retainedText = trimmed

        guard let snapshot = targetSnapshot else {
            _ = control.stage(.targetUnknown)
            publish(phase: .review, interim: trimmed, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return
        }

        // Stages 5-6: transactional validation -> insertion, with retry.
        let outcome = await validateAndInsert(final: final, snapshot: snapshot)
        _ = outcome
    }

    /// Runs validation + insertion once; returns true when the session is
    /// terminal (success/error) and false when a review phase was shown.
    private func validateAndInsert(
        final: EngineResult,
        snapshot: TargetSnapshot
    ) async -> Bool {
        let validation = await provider.validateTarget()
        state.outputs.validation = validation.outcome
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        switch validation.outcome {
        case .validated:
            _ = control.stage(.targetValidationSucceeded)
            // Review R2/4: the LAST cancellation gate — immediately before the
            // transcript-bearing side effect. A cancel during processing must
            // prevent insertion, not just be buffered until review.
            if await checkCancellation() { return true }
            // Round-5 B4: produce the complete, immutable one-use target
            // lease at validation time. The paste path validates the WHOLE
            // lease (PID + process-start + bundle + window + element +
            // capabilities) — not just the bundle — before mutation.
            let lease = TargetLease.make(
                snapshot: snapshot,
                sessionID: sessionID,
                validationDeadlineNanosAhead: 10_000_000_000,  // 10s
                nowNanos: nowNanos())
            let result = await provider.insert(
                SessionInsertRequest(
                    text: retainedText,
                    preferPaste: true,
                    insertionMode: settings.insertionMode,
                    targetBundleID: snapshot.target.bundleID,
                    // Review B4: bind insertion to the VALIDATED element so a
                    // focus change after validation cannot target a different
                    // field/window in the same app.
                    validatedElement: snapshot.element,
                    validatedPid: snapshot.target.pid,
                    validatedWindowID: snapshot.target.windowID,
                    lease: lease,
                    sensitivity: validation.effectiveSensitivity,
                    sessionID: sessionID,
                    copyOnlyOverrides: Set(settings.copyOnlyOverrideBundleIDs)))
            state.outputs.insertion = result
            switch result {
            case .verifiedInserted, .explicitlyCopiedByUser, .eventPostedUnverified:
                // Review B2: a cancel that landed DURING insertion must not be
                // followed by history persistence or a success terminal. Check
                // immediately before both.
                if cancelRequested {
                    await provider.cancel()
                    publish(phase: .hidden, interim: "", level: 0.05)
                    finishTerminal(category: .cancelled)
                    return true
                }
                _ = control.stage(.insertionSucceeded)
                if settings.saveHistory,
                    HistoryStoragePolicy.allowsWrite(
                        sensitivity: validation.effectiveSensitivity,
                        outcome: result)
                {
                    await provider.recordHistory(
                        originalText: final.text,
                        finalText: retainedText,
                        duration: TimeInterval(final.inferenceDurationNanos ?? 0) / 1_000_000_000,
                        modelName: final.engine.modelName)
                }
                // Round-6 B1: a cancel that arrived DURING history persistence
                // cannot change the terminal — insertion already succeeded and
                // the control state is .completed (applied wins). Requesting
                // .cancelled would hit the mismatch guard and strand the
                // session unreleased. Record a content-free warning instead
                // and finish as completed: the run task exits, the broadcaster
                // finishes, exactly one terminal is emitted, and the next
                // session can begin.
                if cancelRequested {
                    telemetrySink.record(
                        TelemetryEvent(
                            sessionID: sessionTelemetryID,
                            kind: .lateCancelAfterInsertion,
                            terminal: nil,
                            durationNanos: nil,
                            atNanos: nowNanos()))
                }
                publish(phase: .success, interim: retainedText, level: state.audioLevel)
                finishTerminal(category: .completed)
                return true
            case .automaticCopy, .automaticCopyBlocked:
                // Review R9 + B3: automatic clipboard writes are never treated
                // as verified completion and never history-eligible. Surface
                // the review panel. Do NOT stage .insertionFailed (which is
                // terminal) — the control model stays in .inserting so
                // retry/discard/cancel remain legal; terminal is set only on
                // actual session end.
                publish(phase: .review, interim: retainedText, level: state.audioLevel)
                await handleReviewCommands(secureOnly: false)
                return true
            default:
                publish(phase: .review, interim: retainedText, level: state.audioLevel)
                await handleReviewCommands(secureOnly: false)
                return true
            }
        case .targetChanged, .targetGone, .notEditable:
            // Review R2/3: do NOT drive the control model to a terminal state
            // before showing review — the session is still alive and retry is
            // legal. The control model STAYS in .resolvingTarget; retry
            // re-stages .targetValidationSucceeded (legal from there), and
            // only the actual session end (retry success / discard / cancel)
            // finalizes a terminal outcome.
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .targetUnknown:
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .secureTarget:
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .deadlineExceeded:
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        }
    }

    /// Review R2/4: check whether a cancel is pending (flag set by cancel(),
    /// read by every side-effecting stage). Non-consuming — does not disturb
    /// the command stream for review phases.
    private func checkCancellation() async -> Bool {
        guard cancelRequested else { return false }
        await provider.cancel()
        publish(phase: .hidden, interim: "", level: 0.05)
        finishTerminal(category: .cancelled)
        return true
    }

    /// Review phase loop: the user may retry (fresh validation/insertion),
    /// dismiss or cancel. The session stays alive until one of those edges.
    /// Consumes the SAME command stream as run() (buffered follow-ups are
    /// never lost when a review phase replaces the capture wait).
    private func handleReviewCommands(secureOnly: Bool) async {
        guard let commands = commandStream else { return }
        for await c in commands {
            switch c {
            case .retry:
                if secureOnly {
                    // Sensitive session: retry re-shows the review (fail closed).
                    publish(phase: .review, interim: retainedText, level: state.audioLevel)
                    continue
                }
                guard let snapshot = targetSnapshot, !retainedText.isEmpty else {
                    publish(phase: .review, interim: retainedText, level: state.audioLevel)
                    continue
                }
                // Fresh validation + insertion against the original target.
                let final = state.outputs.engineResult
                if let final {
                    let done = await validateAndInsert(final: final, snapshot: snapshot)
                    if done { return }
                }
            case .discard, .end:
                publish(phase: .hidden, interim: "", level: 0.05)
                finishTerminal(category: .cancelled)
                return
            case .cancel:
                await provider.cancel()
                _ = control.cancel()
                publish(phase: .hidden, interim: "", level: 0.05)
                finishTerminal(category: .cancelled)
                return
            }
        }
    }
    // MARK: - Internals

    private var sessionAllowsAutomaticSideEffects: Bool {
        targetSnapshot?.sensitivity.sensitivity ?? .unknown == .normal
    }

    private func publish(phase: SessionPhase, interim: String, level: Float) {
        state.phase = phase
        state.interimLength = interim.count
        state.interimText = interim
        state.audioLevel = level
        broadcaster.publish(state)
    }

    /// Exactly-once terminal release: owned tasks cancelled, stream finished.
    /// Round-5 B3: terminal release is ONLY performed when the authoritative
    /// control state accepted the transition AND the reached terminal matches
    /// the requested category. If the machine stayed nonterminal (or reached
    /// a different terminal), the session must NOT claim the requested
    /// terminal: no telemetry, no broadcaster finish, no release — the
    /// mismatch is surfaced (observably) so the caller can reconcile.
    private func finishTerminal(category: TerminalCategory) {
        guard !released else { return }
        // Review R1.5: drive the control state machine to the matching
        // terminal state so the terminal OUTCOME (not just cleanup) is
        // recorded exactly once. A duplicate finish is a no-op because the
        // control model refuses to leave a terminal state.
        let outcomeCategory =
            StageOutcomeCategory(
                rawValue: category.rawValue) ?? .failed
        let reachedState = control.finish(category: outcomeCategory)
        // Round-5 B3: the control state must be TERMINAL and the reached
        // terminal must MATCH the requested category.
        let actualOutcome = SessionControlModel.terminalOutcome(for: reachedState)
        let matches =
            reachedState.isTerminal
            && actualOutcome != nil
            && actualOutcome.flatMap { TerminalCategory(rawValue: $0.rawValue) } == category
        // Round-6 B1: a mismatch must NEVER strand the session. The terminal
        // is emitted with the ACTUAL reached category (applied wins) or a
        // controlled .failed fallback, and release/broadcaster-finish ALWAYS
        // run — with a terminalMismatch marker so the host sees the
        // divergence (the sink is drained after the broadcaster finishes).
        var emittedCategory = category
        if !matches {
            ZFLogPlaceholder.error(
                "terminal state mismatch: requested \(category.rawValue), control reached \(reachedState.rawValue)")
            if let actualOutcome,
                let actual = TerminalCategory(rawValue: actualOutcome.rawValue)
            {
                emittedCategory = actual
            } else {
                emittedCategory = .failed
            }
            telemetrySink.record(
                TelemetryEvent(
                    sessionID: sessionTelemetryID,
                    kind: .terminalMismatch,
                    terminal: emittedCategory,
                    durationNanos: nil,
                    atNanos: nowNanos()))
        }
        released = true
        // Review B3: emit the versioned terminal event exactly once through
        // the TerminalGuard (a second finish is refused). Content-free.
        let now = nowNanos()
        if let event = terminalGuard.finalize(
            terminal: emittedCategory,
            durationNanos: startTime.map { now &- $0 } ?? 0,
            atNanos: now)
        {
            telemetrySink.record(event)
        }
        if let counts = state.outputs.audioSummary {
            telemetrySink.record(
                TelemetryEvent(
                    sessionID: sessionTelemetryID,
                    kind: .captureAccounting,
                    terminal: emittedCategory,
                    frameCounts: FrameCountSnapshot(
                        captured: counts.capturedSourceSamples,
                        delivered: counts.deliveredEngineSamples,
                        dropped: counts.droppedSamples,
                        // Round-5 NIT 5: delivered INPUT is not evidence of
                        // decoded OUTPUT — decoded is unknown at capture time.
                        decoded: 0),
                    atNanos: now))
        }
        captureTask?.cancel()
        levelsTask?.cancel()
        captureTask = nil
        levelsTask = nil
        commandContinuation = nil
        commandStream = nil
        broadcaster.finish()
        // Round-6 B2: the release signal fires only AFTER terminal cleanup
        // and broadcaster completion — awaitTerminalAndReleased() now
        // genuinely means "run() reached terminal and the broadcaster is
        // done", not "the release flag was set".
        releaseContinuation?.yield(())
        releaseContinuation?.finish()
    }
}

/// Logging seam so Core stays AppKit-free and silent in tests.
public enum ZFLogPlaceholder {
    public static func error(_ message: String) {}
}
