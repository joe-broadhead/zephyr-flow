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
    public let sensitivity: SessionSensitivity
    public let sessionID: SessionID
    public let copyOnlyOverrides: Set<String>

    public init(
        text: String, preferPaste: Bool, insertionMode: String,
        targetBundleID: String?, sensitivity: SessionSensitivity,
        sessionID: SessionID, copyOnlyOverrides: Set<String>
    ) {
        self.text = text
        self.preferPaste = preferPaste
        self.insertionMode = insertionMode
        self.targetBundleID = targetBundleID
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
    private var retainedText = ""
    private var released = false

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
    }

    // MARK: - UI subscription (reconnect-safe)

    public func subscribe() -> AsyncStream<SessionUIState> {
        broadcaster.subscribe()
    }

    // MARK: - Control events (hotkey/app path)

    public func end() {
        commandContinuation?.yield(.end)
    }

    public func cancel() {
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
        publish(phase: .listening, interim: "", level: 0.05)

        var commands: AsyncStream<Command>!
        commands = AsyncStream { self.commandContinuation = $0 }
        self.commandStream = commands

        // Session-scoped preparation: AX target snapshot + engine binding.
        await provider.prepare(sessionID: sessionID)
        targetSnapshot = await provider.capturedTargetSnapshot()

        // Stage 1: capture + engine streaming starts immediately (begin edge).
        let handle: SessionCaptureHandle
        do {
            handle = try await provider.startCapture(
                sessionID: sessionID,
                localOnly: settings.localOnly,
                language: settings.language)
        } catch {
            _ = control.stage(.captureFailed)
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

        // Stage 2: stop capture + drain -> audio summary (counts only).
        captureTask?.cancel()
        levelsTask?.cancel()
        let audioSummary = await provider.stopCapture()
        state.outputs.audioSummary = audioSummary
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        if audioSummary.degraded || !audioSummary.reconciled {
            _ = control.stage(.captureFailed)
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .degraded)
            return
        }

        // Stage 3: finalize decode -> explicit engine result.
        _ = control.stage(.drainFinished)
        _ = control.stage(.transcriptionFinished)
        let final: EngineResult
        do {
            final = try await provider.finalize()
        } catch {
            _ = control.stage(.captureFailed)
            publish(phase: .error, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .failed)
            return
        }
        state.outputs.engineResult = final
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

        if final.completeness != .complete {
            _ = control.stage(.targetUnknown)
            publish(phase: .warning, interim: state.interimText, level: state.audioLevel)
            finishTerminal(category: .truncated)
            return
        }

        // Stage 4: Flow — secure/unknown sessions never run structural Flow
        // and never auto-insert (fail-closed review-only, JOE-2259).
        if !sessionAllowsAutomaticSideEffects {
            _ = control.stage(.transformationFinished)
            _ = control.stage(.targetSecure)
            let conservative = await provider.applyFlow(
                FlowRequest(
                    sessionID: sessionID, text: final.text, style: .clean,
                    language: settings.language, sensitivity: .unknown))
            state.outputs.flowOutcome = conservative
            let reviewText = conservative.text.trimmingCharacters(in: .whitespacesAndNewlines)
            retainedText = reviewText
            publish(phase: .review, interim: reviewText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: true)
            return
        }

        _ = control.stage(.transformationFinished)
        let flowOutcome = await provider.applyFlow(
            FlowRequest(
                sessionID: sessionID, text: final.text, style: settings.defaultFlowStyle,
                language: settings.language, sensitivity: .unknown))
        state.outputs.flowOutcome = flowOutcome
        publish(phase: .processing, interim: state.interimText, level: state.audioLevel)

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
            let result = await provider.insert(
                SessionInsertRequest(
                    text: retainedText,
                    preferPaste: true,
                    insertionMode: settings.insertionMode,
                    targetBundleID: snapshot.target.bundleID,
                    sensitivity: validation.effectiveSensitivity,
                    sessionID: sessionID,
                    copyOnlyOverrides: Set(settings.copyOnlyOverrideBundleIDs)))
            state.outputs.insertion = result
            switch result {
            case .verifiedInserted, .explicitlyCopiedByUser, .eventPostedUnverified:
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
                publish(phase: .success, interim: retainedText, level: state.audioLevel)
                finishTerminal(category: .completed)
                return true
            default:
                _ = control.stage(.insertionFailed)
                publish(phase: .review, interim: retainedText, level: state.audioLevel)
                await handleReviewCommands(secureOnly: false)
                return true
            }
        case .targetChanged, .targetGone, .notEditable:
            _ = control.stage(.targetChanged)
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .targetUnknown:
            _ = control.stage(.targetUnknown)
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .secureTarget:
            _ = control.stage(.targetSecure)
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        case .deadlineExceeded:
            _ = control.stage(.deadlineViolated)
            publish(phase: .review, interim: retainedText, level: state.audioLevel)
            await handleReviewCommands(secureOnly: false)
            return true
        }
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
    private func finishTerminal(category: TerminalCategory) {
        guard !released else { return }
        released = true
        captureTask?.cancel()
        levelsTask?.cancel()
        captureTask = nil
        levelsTask = nil
        commandContinuation = nil
        commandStream = nil
        broadcaster.finish()
    }
}

/// Logging seam so Core stays AppKit-free and silent in tests.
public enum ZFLogPlaceholder {
    public static func error(_ message: String) {}
}
