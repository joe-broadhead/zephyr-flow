import AppKit
import Combine
import Foundation
import SwiftUI
import ZephyrFlowCore

/// JOE-2244: thin MainActor UI projection. Session truth, resource ownership
/// and stage orchestration live in the isolated per-session `DictationSession`
/// actor; this coordinator only creates sessions, maps typed UI states and
/// owns app-level responsibilities (permissions, settings/onboarding,
/// hotkey, review actions).
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController(environment: AppEnvironment.production())

    @Published var panelState: PanelState = .hidden
    @Published var interimText: String = ""
    @Published var audioLevels: [Float] = Array(repeating: 0.05, count: 24)
    // JOE-2272: content-free review-panel presentation state.
    @Published var reviewTitle: String?
    @Published var reviewDetail: String?
    @Published var reviewAllowsRetry = false
    @Published var reviewWarnsCopy = false
    @Published var reviewAllowsSettings = false
    @Published var statusMessage: String?
    @Published var isModelLoading = false
    @Published var modelDownloadFraction: Double?
    @Published var activeFlowStyle: FlowStyle = .clean
    @Published var engineLabel: String = "—"

    // JOE-2243: dependency-injected environment.
    private let environment: AppEnvironment
    private let audio = AudioCapture.shared
    private let settingsStore = SettingsStore.shared
    private let privacy = PrivacyService.shared
    private let hotkey = HotkeyService.shared
    private let focus = FocusStore.shared

    private let preparation: EnginePreparationCoordinator
    private var preparationObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    private var preparedEngine: PreparedEngine?
    private var reloadAfterSession = false
    var isSelectedEnginePrepared: Bool {
        guard let preparedEngine else { return false }
        return preparedEngine.request == EnginePreparationRequest(settings: settingsStore.settings)
            && preparation.isCurrent(preparedEngine)
    }
    /// Serializes begin/end/cancel so concurrent hotkey Tasks cannot race.
    private var sessionChain: Task<Void, Never>?
    /// Review R1.4: a begin-session task that may still be in model preload.
    /// A release/cancel arriving during preload cancels this task so the
    /// session does NOT start after the user already released — control is
    /// immediately addressable rather than queued behind long engine work.
    private var pendingBeginTask: Task<Void, Never>?
    /// Review B2v2 (round 5): the press-edge session intent (immutable,
    /// allocated synchronously at the press/toggle edge). Release/cancel
    /// invalidate it immediately even before the queued begin starts.
    private var pendingIntent: PendingSessionIntent?
    private var sessionIntentGeneration: UInt64 = 0
    private var admissionOpen = true
    /// The active per-session actor (nil between sessions). Successive
    /// sessions are distinct actors + providers — no shared mutable state.
    private var session: DictationSession?
    /// Shared monotonic identity source: successive sessions never collide.
    private let sessionIDFactory = SessionIDFactory()
    private var sessionTask: Task<Void, Never>?
    /// Round-6 B2: quarantined shutdown owner — retains a session whose run
    /// task did not quiesce so a late insertion/history mutation cannot be
    /// lost after the handshake abandons.
    private var shutdownQuarantineTask: Task<Void, Never>?
    private var shutdownQuarantineSession: DictationSession?
    private var stateTask: Task<Void, Never>?
    private var reviewModel: InsertionReviewModel?
    private var reviewText: String?
    private var reviewSession: SecureSessionReview?
    private var reviewClearTask: Task<Void, Never>?
    /// Retained for review presentation (session identity is immutable).
    private var lastSessionID: SessionID?
    /// Review REQ-5: the CURRENT session's immutable ID (set at beginSession,
    /// used by sessionDidFinish for a real identity check — NOT overwritten
    /// before the comparison).
    private var currentSessionID: SessionID?
    /// Review R7: true once history key config + load completed (awaited in
    /// start()). Session admission waits for this so history writes are never
    /// made before encryption initialization.
    private var historyReady = false

    init(environment: AppEnvironment, preparation: EnginePreparationCoordinator? = nil) {
        self.environment = environment
        self.preparation = preparation ?? .production(engines: environment.engines)
        preparationObservation = self.preparation.$phase.sink { [weak self] phase in
            self?.isModelLoading = phase.isBusy
            self?.modelDownloadFraction = nil
            self?.statusMessage = phase.message
        }
        settingsObservation = settingsStore.$settings
            .map { EnginePreparationRequest(settings: $0) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // Invalidate at the setting publication edge, including consent
                // revocation and language/privacy changes. The scheduled load
                // reads the updated settings after @Published finishes setting.
                self?.reloadEngine()
            }
        configureFlowRouter()
    }

    // MARK: - Lifecycle

    func start() {
        // JOE-2262 / review R7: at-rest history encryption — non-synchronizing
        // Keychain key, AfterFirstUnlock. Key material never enters
        // logs/metrics/backups/support bundles. Initialization is AWAITED
        // before session admission (history writes are fail-closed until the
        // repository is initialized), and load errors are surfaced rather than
        // swallowed.
        Task {
            let key = HistoryKeychainStore.shared.loadOrCreate()
            await ActorHistoryRepository.shared.configureEncryption(
                keyProvider: { key })
            do {
                try await ActorHistoryRepository.shared.load()
                // Round-5 REQ-5: historyReady reflects the real storage state.
                // When history is DISABLED the storage is marked disabled and
                // dictation proceeds without writes. When enabled, only a
                // ready (encrypted or plaintext) store admits history writes;
                // sealed-key-unavailable / read-failure / corruption surface.
                if !self.settingsStore.settings.saveHistory {
                    await ActorHistoryRepository.shared.markHistoryDisabled()
                    self.historyReady = true
                    ZFLog.info("History disabled — dictation proceeds without writes")
                    return
                }
                let state = await ActorHistoryRepository.shared.storageState
                switch state {
                case .readyEncrypted, .readyPlaintext:
                    // Review B8: historyReady is only true when initialization
                    // SUCCEEDED (a Keychain failure or load error keeps it
                    // false, so session admission errors out instead of
                    // writing).
                    self.historyReady = true
                case .plaintextMigrationPending:
                    // Round-6 REQ-2: with history ENABLED, at-rest encryption
                    // has not actually been established — do NOT admit
                    // history-enabled sessions (the migration persists
                    // plaintext on disk; admitting would write new plaintext).
                    // Surface the recovery action instead.
                    ZFLog.error(
                        "History migration pending — plaintext not yet encrypted; admission blocked")
                    self.historyReady = false
                case .sealedKeyUnavailable, .sealedKeyAuthFailed,
                    .storageReadFailure, .corruptQuarantined:
                    ZFLog.error("History storage not ready: \(state.rawValue)")
                    self.historyReady = false
                case .uninitialized, .historyDisabled:
                    self.historyReady = false
                }
            } catch {
                ZFLog.error("History load failed: \(error.localizedDescription)")
                // historyReady stays false — beginSession will surface the
                // initialization error and refuse to admit a session.
            }
        }
        privacy.refresh()
        hotkey.configure(
            hotkey: settingsStore.settings.hotkey,
            mode: settingsStore.settings.listeningMode
        )
        hotkey.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .press:
                ZFLog.info("Hotkey press")
                // Review B2v2 (round 5): allocate the immutable session intent
                // SYNCHRONOUSLY at the press edge — BEFORE the queued begin
                // operation starts. A release/cancel that arrives while the
                // press is still queued can invalidate this intent even though
                // pendingBeginTask does not exist yet.
                let intent = PendingSessionIntent(
                    generation: self.sessionIntentGeneration &+ 1,
                    pressTimestampNanos: self.environment.clock.nowNanos(),
                    requestedMode: "hotkey")
                self.sessionIntentGeneration = intent.generation
                self.pendingIntent = intent
                self.enqueueSession {
                    // The begin runs inside the sessionChain (serialized);
                    // it checks the intent before/after every await and aborts
                    // if release/cancel already invalidated it.
                    let beginTask = Task { @MainActor in
                        await self.beginSession(intent: intent)
                    }
                    self.pendingBeginTask = beginTask
                    await beginTask.value
                    if self.pendingIntent?.generation == intent.generation {
                        self.pendingIntent = nil
                    }
                }
            case .release:
                ZFLog.info("Hotkey release")
                // Review B2v2 (round 5): invalidate the press-edge intent
                // IMMEDIATELY (synchronously), so even a begin that is still
                // queued (pendingBeginTask not yet created) observes the
                // cancellation before it starts preparation/capture.
                if let intent = self.pendingIntent {
                    intent.cancel()
                    self.pendingIntent = nil
                }
                // Review R1.4: preempt a pending begin DURING model preload
                // immediately (not through the sessionChain FIFO). Without
                // this, a release during a slow engine load queues behind the
                // begin and the session still starts after the user released.
                if self.session == nil, let pending = self.pendingBeginTask,
                    !pending.isCancelled
                {
                    pending.cancel()
                    self.pendingBeginTask = nil
                    ZFLog.info("Hotkey release preempted pending begin during model preload")
                }
                self.enqueueSession { await self.endSession() }
            }
        }
        // No background preparation before completed onboarding. Download
        // consent remains a separate setting; its default is not changed here.
        if settingsStore.settings.hasCompletedOnboarding {
            Task.detached { [weak self] in
                await self?.preloadEngine()
            }
        }
        Task { await self.ensurePermissionsUpFront() }
        ZFLog.info("DictationController started hotkey=\(settingsStore.settings.hotkey.displayName)")
    }

    private func ensurePermissionsUpFront() async {
        privacy.refresh()
        let needUI =
            !privacy.status.microphone
            || (settingsStore.settings.preferredModel == .appleSpeech && !privacy.status.speechRecognition)
            || (settingsStore.settings.insertionMode != .alwaysCopy && !privacy.status.accessibility)
        guard needUI else { return }
        if !settingsStore.settings.hasCompletedOnboarding {
            ZFLog.info("Permission preflight deferred to onboarding")
            return
        }
        ZFLog.info("Missing permissions after onboarding — reopening Setup")
        await MainActor.run {
            WindowRouter.openOnboarding()
        }
    }

    /// JOE-2266: 7-step termination handshake (deadline-bounded).
    func terminate(deadlineNanosAhead: UInt64 = 3_000_000_000) async -> TerminationState {
        var handshake = TerminationHandshake(deadlineNanosAhead: deadlineNanosAhead)
        let t0 = environment.clock.nowNanos()
        handshake.begin(nowNanos: t0)
        let now = { self.environment.clock.nowNanos() }

        // 1. Close new-session/hotkey admission first.
        hotkey.stop()
        admissionOpen = false
        pendingIntent?.cancel()
        pendingIntent = nil
        pendingBeginTask?.cancel()
        preparation.cancel()
        _ = handshake.completeStep(.admissionClosed, nowNanos: now())

        // 2. Finish/cancel the active session (single terminal outcome in the
        // per-session actor; exactly-once release happens there).
        // Review B2v2 (round 5): do NOT claim sessionFinished until the
        // session's run() task has reached terminal release. Join with a
        // bounded deadline; if the session is still running (e.g. suspended
        // in insertion/history), the handshake enters the abandoned path and
        // the recovery marker records the incomplete shutdown.
        if let session {
            sessionTask?.cancel()
            await session.cancel()
            let joined = await session.awaitTerminalAndReleased(
                deadlineNanosAhead: 2_000_000_000)
            // Round-6 B2: join the RUN TASK ITSELF with a bounded deadline by
            // racing `task.value` against the deadline — NOT by polling
            // `task.isCancelled` (a cancellation flag is not completion, so
            // the old loop ran zero iterations). This proves run() actually
            // returned and terminal cleanup finished.
            var runExited = joined
            if let task = sessionTask, !joined {
                let taskJoined = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        await task.value
                        return true
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                runExited = taskJoined
            }
            if runExited {
                // Only clear ownership when the run task actually exited; a
                // still-running task is moved to a quarantined shutdown owner
                // so it cannot be lost while mutating insertion/history.
                sessionTask = nil
                stateTask?.cancel()
                stateTask = nil
                self.session = nil
            } else {
                ZFLog.error(
                    "termination: session run task did not quiesce — retaining quarantined shutdown owner")
                // Retain the task/session (quarantined shutdown owner) and
                // abandon the handshake: do NOT claim sessionFinished,
                // pasteboardResolved or sessionCompleted.
                self.shutdownQuarantineTask = sessionTask
                self.shutdownQuarantineSession = session
                sessionTask = nil
                stateTask?.cancel()
                stateTask = nil
                self.session = nil
                _ = handshake.abandon(reason: "session run task did not quiesce")
            }
        }
        if handshake.state != .abandoned {
            _ = handshake.completeStep(.sessionFinished, nowNanos: now())
        }

        // 3. Audio already owned/released by the session's provider; ensure the
        // shared capture is stopped.
        await audio.stop()
        _ = handshake.completeStep(.audioStopped, nowNanos: now())

        // 4. Quiesce engines with a bounded deadline.
        await preparedEngine?.engine.cancel()
        if preparation.outstandingWorkers == 0 {
            _ = handshake.completeStep(.enginesQuiesced, nowNanos: now())
        } else {
            _ = handshake.abandon(reason: "model preparation still owns native work")
        }

        // 5. Pasteboard restoration resolved inside the insert transaction.
        //    Round-6 B2/NIT 5: when the handshake is abandoned (session did
        //    not quiesce), do NOT claim pasteboard resolution — an insertion
        //    may still be in flight.
        if handshake.state != .abandoned {
            _ = handshake.completeStep(.pasteboardResolved, nowNanos: now())
        }

        // 6. Flush settings/history/metrics. Round-6 NIT 5: never emit
        //    sessionCompleted as a generic storage-flush marker — it is a
        //    session-outcome event; only emit it for a successfully completed
        //    session handshake.
        settingsStore.save()
        if handshake.state == .completed {
            await environment.metrics.record(
                MetricsEvent(kind: .sessionCompleted, value: 0, atNanos: now()))
        }
        _ = handshake.completeStep(.storageFlushed, nowNanos: now())

        // 7. Restore the retained Fn/global preference exactly.
        HotkeyService.restoreFnOverrideIfNeededFromPriorLaunch()
        _ = handshake.completeStep(.preferencesRestored, nowNanos: now())

        reviewSession?.clear(reason: .appTerminating)
        reviewSession = nil
        return handshake.state
    }

    func stop() {
        hotkey.stop()
        admissionOpen = false
        pendingIntent?.cancel()
        pendingIntent = nil
        pendingBeginTask?.cancel()
        preparation.cancel()
        sessionTask?.cancel()
        stateTask?.cancel()
        sessionTask = nil
        stateTask = nil
        if let session {
            Task { await session.cancel() }
        }
        session = nil
        reviewSession?.clear(reason: .appTerminating)
        reviewSession = nil
        reviewClearTask?.cancel()
        reviewClearTask = nil
        panelState = .hidden
        interimText = ""
        FloatingPanelController.shared.hide()
        ZFLog.info("DictationController stopped")
    }

    // MARK: - Session (thin projection)

    private func beginSession(intent: PendingSessionIntent? = nil) async {
        // Review B2v2 (round 5): the intent is invalidated synchronously at
        // the press edge by release/cancel — a begin that was still queued
        // aborts here without preparing or activating the microphone.
        if intent?.isCancelled == true || Task.isCancelled {
            ZFLog.info("beginSession aborted — session intent already cancelled")
            pendingBeginTask = nil
            return
        }
        guard admissionOpen, session == nil else {
            ZFLog.info("beginSession ignored — admission closed or session active")
            return
        }
        // Review R7: do not admit a session until history encryption init has
        // completed (fail-closed; a Keychain failure surfaces as an error).
        if !historyReady {
            ZFLog.info("beginSession waiting for history initialization")
            var waited: UInt64 = 0
            while !historyReady, waited < 5_000_000_000 {
                // Review B2v2 (round 5): a release/cancel during the history
                // wait must abort the begin, not start it after the user
                // already released.
                if intent?.isCancelled == true || Task.isCancelled || !admissionOpen {
                    pendingBeginTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 50_000_000
            }
            if !historyReady {
                showError("History storage could not be initialized — check Keychain access.")
                return
            }
            if intent?.isCancelled == true {
                pendingBeginTask = nil
                return
            }
        }
        // Review B2: DO NOT clear pendingBeginTask here — the release handler
        // needs it set DURING model readiness/preload so it can preempt a
        // begin that is still waiting on the engine. It is cleared only when
        // the session actually begins (below) or the begin is cancelled.
        // App-level fail-fast permission checks (never await dialogs here).
        let requestedSettings = settingsStore.settings
        privacy.refresh()
        guard privacy.status.microphone else {
            pendingBeginTask = nil
            showError("Microphone permission required")
            Task { await ensurePermissionsUpFront() }
            return
        }
        if requestedSettings.preferredModel == .appleSpeech && !privacy.status.speechRecognition {
            pendingBeginTask = nil
            showError("Speech Recognition permission required")
            Task { await ensurePermissionsUpFront() }
            return
        }

        let candidate = await preparation.prepare(EnginePreparationRequest(settings: requestedSettings))
        // Review B2: a release during preload cancelled us — do NOT start.
        // (The release handler cancels pendingBeginTask directly; this check
        // catches the cancel and aborts before any capture begins.)
        if Task.isCancelled {
            pendingBeginTask = nil
            return
        }
        guard settingsStore.settings == requestedSettings, intent?.isCancelled != true, admissionOpen else {
            pendingBeginTask = nil
            return
        }
        // JOE-2283: never enter a fake listening/capturing state when the
        // selected model is not ready (missing/unverified/failed download).
        guard let candidate, preparation.isCurrent(candidate) else {
            pendingBeginTask = nil
            guard !preparation.phase.isBusy, preparation.phase != .cancelled else { return }
            showError(preparation.phase.message ?? AppStrings.key("engine.preparation.notloaded"))
            return
        }
        guard admissionOpen, session == nil else { return }
        guard settingsStore.settings == requestedSettings, intent?.isCancelled != true else {
            pendingBeginTask = nil
            return
        }
        preparedEngine = candidate
        engineLabel = candidate.request.model.displayName

        // Remember where the user was typing BEFORE any of our UI steals focus.
        focus.captureNow()

        activeFlowStyle = requestedSettings.defaultFlowStyle
        panelState = .listening
        interimText = ""
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)

        // Build a FRESH provider + FRESH actor per session: no shared mutable
        // tasks, buffers, target identity or callbacks across sessions.
        let settings = SessionSettingsSnapshot(
            localOnly: requestedSettings.localOnlyMode,
            language: requestedSettings.language,
            defaultFlowStyle: requestedSettings.defaultFlowStyle,
            insertionMode: requestedSettings.insertionMode.rawValue,
            saveHistory: requestedSettings.saveHistory,
            copyOnlyOverrideBundleIDs: Array(requestedSettings.copyOnlyOverrideBundleIDs))
        let provider = ProductionSessionStages(
            environment: environment,
            engine: candidate.engine,
            engineKind: candidate.request.model.isWhisperKit ? .whisper : .appleSpeech,
            engineToken: candidate.token)
        // Review B2v2 (round 5): final intent check immediately before
        // session creation — the user may have released during the last
        // model-readiness await.
        if intent?.isCancelled == true {
            pendingBeginTask = nil
            ZFLog.info("beginSession aborted — intent cancelled before session creation")
            return
        }
        let s = DictationSession(
            provider: provider,
            engineChoice: candidate.request.model.isWhisperKit ? .whisper : .appleSpeech,
            settings: settings,
            idFactory: sessionIDFactory)
        session = s
        pendingBeginTask = nil  // begin completed; no longer pending
        // Review REQ-4: set the session ID authoritatively BEFORE any review
        // or completion can run (no separate racy task). The ID is immutable
        // and available immediately; review presentation and the completion
        // identity check both read it.
        self.lastSessionID = await s.sessionID
        self.currentSessionID = await s.sessionID
        sessionTask = Task { await s.run() }
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await s.subscribe() {
                self.apply(state)
            }
            // Review R1.6: the broadcaster finished -> the session reached a
            // terminal phase. Clear this session's references exactly once
            // (identity-checked) so a LATER session can begin; without this,
            // session != nil forever and beginSession() rejects every
            // subsequent attempt.
            let sessionID = await s.sessionID
            await MainActor.run {
                self.sessionDidFinish(sessionID: sessionID)
            }
        }
        ZFLog.info("Session begun (session allocated)")
    }

    private func endSession() async {
        guard let session else {
            ZFLog.info("endSession ignored — no active session")
            return
        }
        panelState = .processing
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        await session.end()
    }

    func cancelSession() {
        if session == nil { preparation.cancel() }
        // Review B2v2 (round 5): invalidate the press-edge intent immediately
        // so a still-queued begin aborts before starting.
        if let intent = self.pendingIntent {
            intent.cancel()
            self.pendingIntent = nil
        }
        // Review B2v2: a cancel during model preload must preempt the pending
        // begin directly (session is nil then), not queue behind it.
        if self.session == nil, let pending = self.pendingBeginTask,
            !pending.isCancelled
        {
            pending.cancel()
            self.pendingBeginTask = nil
            ZFLog.info("cancelSession preempted pending begin during preload")
        }
        enqueueSession {
            await self.session?.cancel()
        }
    }

    /// Panel "stop & insert" button.
    func stopAndInsert() {
        if session == nil {
            cancelSession()
            return
        }
        enqueueSession {
            await self.session?.end()
        }
    }

    func toggleManualSession() {
        // Round-6 B2: a second toggle while the first begin is STILL QUEUED
        // (session nil, pending intent present) must PREEMPT it — cancel the
        // existing intent instead of overwriting it (the old code replaced
        // pendingIntent and queued a second operation, so intent 1 stayed
        // valid and could start the microphone).
        if self.session == nil, let existing = self.pendingIntent {
            existing.cancel()
            self.pendingIntent = nil
            self.pendingBeginTask?.cancel()
            ZFLog.info("toggle preempted pending begin (no new session)")
            return
        }
        // Review B2v2 (round 5): the manual toggle also creates an intent at
        // the action edge so a second toggle can preempt model work.
        let intent = PendingSessionIntent(
            generation: self.sessionIntentGeneration &+ 1,
            pressTimestampNanos: self.environment.clock.nowNanos(),
            requestedMode: "manual-toggle")
        self.sessionIntentGeneration = intent.generation
        self.pendingIntent = intent
        enqueueSession {
            if self.session == nil {
                let beginTask = Task { @MainActor in await self.beginSession(intent: intent) }
                self.pendingBeginTask = beginTask
                await beginTask.value
            } else {
                await self.endSession()
            }
            if self.pendingIntent?.generation == intent.generation {
                self.pendingIntent = nil
            }
        }
    }

    func applyQuickAction(_ style: FlowStyle) {
        activeFlowStyle = style
    }

    // MARK: - Review actions (app-level; decisions forward to the actor)

    func retryReview() {
        guard reviewModel?.allowsRetry == true, reviewText != nil else { return }
        guard var model = reviewModel else { return }
        _ = model.consume(.retryValidation, nowNanos: environment.clock.nowNanos())
        reviewModel = model
        clearReview(reason: .retriedWithFreshIntent)
        Task { await self.session?.retryInsertion() }
    }

    func discardReview() {
        clearReview(reason: .userDismissed)
        Task { await self.session?.discard() }
    }

    func copyReviewContent() {
        guard let text = reviewText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied to clipboard — paste where you need it"
        clearReview(reason: .consumedByExplicitCopy)
        Task { await self.session?.discard() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func clearReview(reason: SecureSessionReview.ClearReason) {
        reviewSession?.clear(reason: reason)
        reviewSession = nil
        reviewModel = nil
        reviewText = nil
        reviewClearTask?.cancel()
        reviewClearTask = nil
        panelState = .hidden
        interimText = ""
        FloatingPanelController.shared.hide()
        hotkey.resetToggle()
    }

    // MARK: - UI state mapping (actor -> projection)

    /// Review R1.6: identity-checked exactly-once completion. Clears the
    /// completed session's references (session/task/stateTask) only if it is
    /// still the current session, resets hotkey toggle state where needed,
    /// then applies terminal UI dismissal policy. Called when the session's
    /// state broadcaster finishes.
    private func sessionDidFinish(sessionID: SessionID) {
        // Review REQ-5: compare the finishing ID against the CURRENT session's
        // ID (set at beginSession). Do NOT overwrite lastSessionID first —
        // that made the identity check tautologically true and could not
        // detect a stale completion from an older session.
        let isCurrent: Bool
        if let currentID = currentSessionID {
            isCurrent = (currentID == sessionID)
        } else {
            isCurrent = true
        }
        guard isCurrent else {
            ZFLog.info("Session finish ignored — a newer session is active")
            return
        }
        // Authoritative: this finished session IS (or was) the current one.
        lastSessionID = sessionID
        currentSessionID = nil
        // Review B3v2: forward the session's terminal telemetry to the
        // production metrics sink (the session's private sink would otherwise
        // become unreachable when the session is released).
        if let session {
            Task {
                let events = await session.drainTelemetry()
                for event in events where event.kind == .terminal {
                    // Round-5 B3: forward the EXACT terminal category (never
                    // collapse failed/truncated/secure/deadline into
                    // sessionCompleted — they must be distinguishable in the
                    // production sink).
                    let kind: MetricsEventKind
                    switch event.terminal {
                    case .completed: kind = .sessionCompleted
                    case .degraded: kind = .sessionDegraded
                    case .partial: kind = .sessionPartial
                    case .truncated: kind = .sessionTruncated
                    case .cancelled: kind = .sessionCancelled
                    case .failed: kind = .sessionFailed
                    case .deadlineExceeded: kind = .sessionDeadlineExceeded
                    case .secureTarget: kind = .sessionSecureTarget
                    case .targetChanged: kind = .targetChanged
                    case .abandonedDuringShutdown: kind = .sessionAbandoned
                    case nil:
                        // Terminal event without a category: record failed.
                        kind = .sessionFailed
                    }
                    await self.environment.metrics.record(
                        MetricsEvent(kind: kind, value: event.durationNanos ?? 0, atNanos: event.atNanos))
                }
            }
        }
        sessionTask?.cancel()
        sessionTask = nil
        stateTask = nil
        session = nil
        if reloadAfterSession {
            reloadAfterSession = false
            reloadEngine()
        }
        ZFLog.info("Session finished and cleared (identity-checked)")
        // Review REQ-4: do NOT unconditionally dismiss the panel. Success
        // already dismissed itself in apply(); warning/review/error terminal
        // states are PERSISTENT and must stay visible so the user can act.
        // Only dismiss if the panel already resolved (success/hidden).
        if panelState == .success || panelState == .hidden {
            dismissPanelSoon()
        }
    }

    private func apply(_ state: SessionUIState) {
        switch state.phase {
        case .listening:
            panelState = .listening
            interimText = state.interimText
        case .processing:
            panelState = .processing
        case .success:
            interimText = state.interimText
            let presentation = UIStatePolicy.presentation(
                engineCompleteness: state.outputs.engineResult?.completeness ?? .complete,
                flowStatus: state.outputs.flowOutcome?.status ?? .accepted,
                insertion: state.outputs.insertion ?? .failed("Insertion outcome unavailable"))
            statusMessage = presentation.message
            switch presentation.semantic {
            case .verifiedSuccess, .neutral:
                panelState = .success
                dismissPanelSoon()
            case .unverifiedPosted:
                panelState = .warning
            case .review:
                presentReview(
                    outcome: state.outputs.insertion ?? .failed("Insertion outcome unavailable"),
                    text: state.interimText)
            case .warning:
                panelState = .warning
            case .error:
                panelState = .error(presentation.title ?? "Insertion issue")
            case .processing:
                panelState = .processing
            }
        case .warning:
            panelState = .warning
            statusMessage = "Transcript incomplete — discarded"
        case .review:
            if let insertion = state.outputs.insertion {
                presentReview(outcome: insertion, text: state.interimText)
            } else if let validation = state.outputs.validation {
                presentReview(
                    outcome: Self.reviewOutcome(for: validation),
                    text: state.interimText)
            } else {
                // Secure/unknown session review (JOE-2259).
                presentSecureReview(state.interimText)
            }
        case .error:
            showError("Session failed")
        case .hidden:
            panelState = .hidden
            interimText = ""
            FloatingPanelController.shared.hide()
        case .idle:
            break
        }
    }

    /// Persistent review panel for uncertain outcomes (JOE-2272).
    private func presentReview(outcome: InsertionOutcome, text: String) {
        let now = environment.clock.nowNanos()
        let model = InsertionReviewModel(outcome: outcome, createdAtNanos: now)
        reviewModel = model
        reviewText = text
        guard let sid = lastSessionID else { return }
        let review = SecureSessionReview(
            sessionID: sid, text: text,
            nowNanos: now,
            deadlineNanosAhead: 30_000_000_000)
        reviewSession = review
        interimText = text
        reviewTitle = model.title
        reviewDetail = model.detail
        reviewAllowsRetry = model.allowsRetry
        reviewWarnsCopy = model.shouldWarnBeforeCopy
        reviewAllowsSettings = model.allowsOpenAccessibilitySettings
        panelState = .reviewing
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        reviewClearTask?.cancel()
        reviewClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            await MainActor.run { self.clearReview(reason: .deadlineExpired) }
        }
        ZFLog.info("review presented outcome=\(outcome) len=\(text.count)")
    }

    /// Review-only surface for secure/unknown sessions (JOE-2259).
    private func presentSecureReview(_ text: String) {
        guard let sid = lastSessionID else { return }
        let review = SecureSessionReview(
            sessionID: sid, text: text,
            nowNanos: environment.clock.nowNanos(),
            deadlineNanosAhead: 30_000_000_000)
        reviewSession = review
        reviewText = text
        interimText = text
        reviewTitle = "Sensitive session — review only"
        reviewDetail =
            "This session was not automatically inserted. Copy the text below and paste it where you need it."
        reviewAllowsRetry = false
        reviewWarnsCopy = true
        reviewAllowsSettings = false
        panelState = .reviewing
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        reviewClearTask?.cancel()
        reviewClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            await MainActor.run { self.clearReview(reason: .deadlineExpired) }
        }
        ZFLog.info("Sensitive session review-only len=\(text.count)")
    }

    // MARK: - Engine

    func reloadHotkey() {
        // Full restart so Fn system override + tap config apply cleanly.
        hotkey.stop()
        hotkey.configure(
            hotkey: settingsStore.settings.hotkey,
            mode: settingsStore.settings.listeningMode
        )
        hotkey.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .press:
                ZFLog.info("Hotkey press")
                // Review B2v2 (round 5): allocate the immutable session intent
                // SYNCHRONOUSLY at the press edge — BEFORE the queued begin
                // operation starts. A release/cancel that arrives while the
                // press is still queued can invalidate this intent even though
                // pendingBeginTask does not exist yet.
                let intent = PendingSessionIntent(
                    generation: self.sessionIntentGeneration &+ 1,
                    pressTimestampNanos: self.environment.clock.nowNanos(),
                    requestedMode: "hotkey")
                self.sessionIntentGeneration = intent.generation
                self.pendingIntent = intent
                self.enqueueSession {
                    // The begin runs inside the sessionChain (serialized);
                    // it checks the intent before/after every await and aborts
                    // if release/cancel already invalidated it.
                    let beginTask = Task { @MainActor in
                        await self.beginSession(intent: intent)
                    }
                    self.pendingBeginTask = beginTask
                    await beginTask.value
                    if self.pendingIntent?.generation == intent.generation {
                        self.pendingIntent = nil
                    }
                }
            case .release:
                ZFLog.info("Hotkey release")
                // Review B2v2 (round 5): invalidate the press-edge intent
                // IMMEDIATELY (synchronously), so even a begin that is still
                // queued (pendingBeginTask not yet created) observes the
                // cancellation before it starts preparation/capture.
                if let intent = self.pendingIntent {
                    intent.cancel()
                    self.pendingIntent = nil
                }
                // Review R1.4: preempt a pending begin DURING model preload
                // immediately (not through the sessionChain FIFO). Without
                // this, a release during a slow engine load queues behind the
                // begin and the session still starts after the user released.
                if self.session == nil, let pending = self.pendingBeginTask,
                    !pending.isCancelled
                {
                    pending.cancel()
                    self.pendingBeginTask = nil
                    ZFLog.info("Hotkey release preempted pending begin during model preload")
                }
                self.enqueueSession { await self.endSession() }
            }
        }
        ZFLog.info("Hotkey reloaded \(settingsStore.settings.hotkey.displayName)")
    }

    /// Reload the current engine (menu/settings action).
    func reloadEngine() {
        guard session == nil else {
            reloadAfterSession = true
            statusMessage = AppStrings.key("engine.preparation.deferred")
            return
        }
        // Supersede synchronously at the selection edge, not inside a queued
        // Task. A late completion cannot win before the replacement starts.
        preparation.cancel()
        Task { await preloadEngine() }
    }

    func cancelModelPreparation() {
        preparation.cancel()
        if session == nil {
            pendingIntent?.cancel()
            pendingIntent = nil
            pendingBeginTask?.cancel()
        }
    }

    /// Explicit setup action using the same current-candidate admission path.
    /// It loads/checks capabilities only; it never activates a microphone.
    func prepareSelectedEngine(retry: Bool = false) async -> Bool {
        guard session == nil else { return false }
        if retry { preparation.cancel() }
        return await preloadEngine()
    }

    /// Same coordinator as session admission; Apple Speech is selected from
    /// settings and loaded explicitly. Artifact verification and engine load
    /// are distinct phases. No active-session engine is mutated by reloading.
    private func preloadEngine() async -> Bool {
        guard session == nil, admissionOpen else { return false }
        let request = EnginePreparationRequest(settings: settingsStore.settings)
        guard let candidate = await preparation.prepare(request), preparation.isCurrent(candidate),
            request == EnginePreparationRequest(settings: settingsStore.settings),
            session == nil, admissionOpen, !Task.isCancelled
        else { return false }
        preparedEngine = candidate
        engineLabel = request.model.displayName
        return true
    }

    private func configureFlowRouter() {
        let store = settingsStore
        Task {
            let enhanced = EnhancedFlowProcessor.shared
            await enhanced.refreshAvailability()
            await FlowRouter.shared.configure(
                backend: { await MainActor.run { store.settings.flowBackend } },
                enhancedReady: { true },
                enhanced: enhanced)
        }
    }

    // MARK: - Hotkey serialization

    private func enqueueSession(_ op: @escaping @MainActor () async -> Void) {
        let previous = sessionChain
        sessionChain = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    // MARK: - Demo / screenshots (no audio)

    func prepareDemoPanelForScreenshot() {
        interimText = "Private voice-to-text at your cursor…"
        audioLevels = (0..<24).map { i in
            Float(0.15 + 0.55 * abs(sin(Double(i) * 0.45)))
        }
        activeFlowStyle = settingsStore.settings.defaultFlowStyle
        panelState = .listening
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        FloatingPanelController.shared.resizeToFit()
    }

    func clearDemoPanelForScreenshot() {
        panelState = .hidden
        interimText = ""
        FloatingPanelController.shared.hide()
    }

    // MARK: - UI helpers

    /// Content-free mapping: validation outcome -> review-panel outcome.
    private static func reviewOutcome(for validation: TargetValidationOutcome) -> InsertionOutcome {
        switch validation {
        case .validated: return .failed("Validation did not converge")
        case .targetChanged: return .targetChanged
        case .targetGone: return .targetGone
        case .targetUnknown: return .targetUnknown
        case .secureTarget: return .secureTarget
        case .notEditable: return .notEditable
        case .deadlineExceeded: return .deadlineExceeded
        }
    }

    private func showError(_ message: String) {
        panelState = .error(message)
        statusMessage = message
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard let self, self.session == nil else { return }
            if case .error = self.panelState {
                self.panelState = .hidden
                FloatingPanelController.shared.hide()
            }
        }
    }

    private func dismissPanelSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.session == nil else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                self.panelState = .hidden
                self.interimText = ""
            }
            FloatingPanelController.shared.hide()
        }
    }

    func clearStatusLater() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self else { return }
            self.statusMessage = nil
        }
    }
}
