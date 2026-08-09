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
    private let modelReadiness = ModelReadinessStore.shared
    private let focus = FocusStore.shared

    private var appleEngine = AppleSpeechEngine()
    private var whisperEngine = WhisperKitEngine()
    private var activeEngine: any WhisperEngineProtocol
    private var usingAppleEngine = false
    /// Bumped on engine switch; each session captures its own token.
    private var currentEngineToken = EngineToken()
    /// Serializes begin/end/cancel so concurrent hotkey Tasks cannot race.
    private var sessionChain: Task<Void, Never>?
    /// Review R1.4: a begin-session task that may still be in model preload.
    /// A release/cancel arriving during preload cancels this task so the
    /// session does NOT start after the user already released — control is
    /// immediately addressable rather than queued behind long engine work.
    private var pendingBeginTask: Task<Void, Never>?
    private var admissionOpen = true
    /// The active per-session actor (nil between sessions). Successive
    /// sessions are distinct actors + providers — no shared mutable state.
    private var session: DictationSession?
    /// Shared monotonic identity source: successive sessions never collide.
    private let sessionIDFactory = SessionIDFactory()
    private var sessionTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var reviewModel: InsertionReviewModel?
    private var reviewText: String?
    private var reviewSession: SecureSessionReview?
    private var reviewClearTask: Task<Void, Never>?
    /// Retained for review presentation (session identity is immutable).
    private var lastSessionID: SessionID?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.activeEngine = whisperEngine
        configureFlowRouter()
    }

    // MARK: - Lifecycle

    func start() {
        // JOE-2262: at-rest history encryption — non-synchronizing Keychain
        // key, AfterFirstUnlock (launch-at-login compatible). Key material
        // never enters logs/metrics/backups/support bundles.
        Task {
            let key = HistoryKeychainStore.shared.loadOrCreate()
            await ActorHistoryRepository.shared.configureEncryption(
                keyProvider: { key })
            try? await ActorHistoryRepository.shared.load()
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
                let task = Task { @MainActor in await self.beginSession() }
                self.pendingBeginTask = task
                self.enqueueSession { await task.value }
            case .release:
                ZFLog.info("Hotkey release")
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
        // Review R6.1: do NOT preload/acquire models before onboarding
        // consent. With downloads default-off and this gate, a fresh install
        // cannot fetch a model until the user explicitly enables it in
        // onboarding/settings. Detached so SFSpeech/mic permission callbacks
        // (main queue) cannot deadlock with @MainActor awaiting the engine.
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
            || !privacy.status.speechRecognition
            || !privacy.status.accessibility
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
        _ = handshake.completeStep(.admissionClosed, nowNanos: now())

        // 2. Finish/cancel the active session (single terminal outcome in the
        // per-session actor; exactly-once release happens there).
        if let session {
            sessionTask?.cancel()
            await session.cancel()
            sessionTask = nil
            stateTask?.cancel()
            stateTask = nil
            self.session = nil
        }
        _ = handshake.completeStep(.sessionFinished, nowNanos: now())

        // 3. Audio already owned/released by the session's provider; ensure the
        // shared capture is stopped.
        await audio.stop()
        _ = handshake.completeStep(.audioStopped, nowNanos: now())

        // 4. Quiesce engines with a bounded deadline.
        await activeEngine.cancel()
        _ = handshake.completeStep(.enginesQuiesced, nowNanos: now())

        // 5. Pasteboard restoration resolved inside the insert transaction.
        _ = handshake.completeStep(.pasteboardResolved, nowNanos: now())

        // 6. Flush settings/history/metrics.
        settingsStore.save()
        await environment.metrics.record(
            MetricsEvent(kind: .sessionCompleted, value: 0, atNanos: now()))
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

    private func beginSession() async {
        guard admissionOpen, session == nil else {
            ZFLog.info("beginSession ignored — admission closed or session active")
            return
        }
        // If we're actually running begin now, a prior pending reference is
        // stale (e.g. a cancelled one); clear it so a future release sees the
        // real current pending task (set by the press handler).
        pendingBeginTask = nil
        // App-level fail-fast permission checks (never await dialogs here).
        privacy.refresh()
        guard privacy.status.microphone else {
            showError("Microphone permission required")
            Task { await ensurePermissionsUpFront() }
            return
        }
        if usingAppleEngine && !privacy.status.speechRecognition {
            showError("Speech Recognition permission required")
            Task { await ensurePermissionsUpFront() }
            return
        }

        // Surface model download state if Whisper isn't ready yet.
        if !usingAppleEngine {
            let model = settingsStore.settings.preferredModel
            let ready = ModelReadinessStore.shared.readiness(for: model)
            if case .downloading = ready.state {
                interimText = ModelReadinessStore.shared.bannerMessage ?? "Downloading model…"
            } else if case .failed(let msg) = ready.state {
                showError(msg)
                return
            }
        }

        let ready = await activeEngine.isReady
        if !ready {
            await preloadEngine()
        }
        // Review R1.4: a release during preload cancelled us — do NOT start.
        if Task.isCancelled { return }
        // JOE-2283: never enter a fake listening/capturing state when the
        // selected model is not ready (missing/unverified/failed download).
        guard await activeEngine.isReady else {
            showError("Selected model is not ready — download or verify it in Settings, or switch to Apple Speech.")
            return
        }
        guard admissionOpen, session == nil else { return }

        // Remember where the user was typing BEFORE any of our UI steals focus.
        focus.captureNow()

        activeFlowStyle = settingsStore.settings.defaultFlowStyle
        panelState = .listening
        interimText = ""
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)

        // Build a FRESH provider + FRESH actor per session: no shared mutable
        // tasks, buffers, target identity or callbacks across sessions.
        let settings = SessionSettingsSnapshot(
            localOnly: settingsStore.settings.localOnlyMode,
            language: settingsStore.settings.language,
            defaultFlowStyle: settingsStore.settings.defaultFlowStyle,
            insertionMode: settingsStore.settings.insertionMode.rawValue,
            saveHistory: settingsStore.settings.saveHistory,
            copyOnlyOverrideBundleIDs: Array(settingsStore.settings.copyOnlyOverrideBundleIDs))
        let provider = ProductionSessionStages(
            environment: environment,
            engine: activeEngine,
            engineKind: usingAppleEngine ? .appleSpeech : .whisper,
            engineToken: currentEngineToken)
        let s = DictationSession(
            provider: provider,
            engineChoice: usingAppleEngine ? .appleSpeech : .whisper,
            settings: settings,
            idFactory: sessionIDFactory)
        session = s
        pendingBeginTask = nil  // begin completed; no longer pending
        sessionTask = Task { await s.run() }
        // SessionID is immutable; read it for review presentation.
        Task { [weak self] in
            guard let self else { return }
            self.lastSessionID = await s.sessionID
        }
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
        enqueueSession {
            await self.session?.cancel()
        }
    }

    /// Panel "stop & insert" button.
    func stopAndInsert() {
        enqueueSession {
            await self.session?.end()
        }
    }

    func toggleManualSession() {
        enqueueSession {
            if self.session == nil {
                await self.beginSession()
            } else {
                await self.endSession()
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
        // Identity check: only clear if this finished session is still the
        // active one (a newer session may have replaced it). lastSessionID is
        // updated at session start, so comparing it to the finished id keeps
        // a stale completion from wiping a newer session's references.
        let isCurrent: Bool
        if let currentID = lastSessionID {
            isCurrent = (currentID == sessionID)
        } else {
            isCurrent = true
        }
        guard isCurrent else {
            ZFLog.info("Session finish ignored — a newer session is active")
            return
        }
        sessionTask?.cancel()
        sessionTask = nil
        stateTask = nil
        session = nil
        ZFLog.info("Session finished and cleared (identity-checked)")
        // Terminal UI dismissal (idempotent).
        dismissPanelSoon()
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
                let task = Task { @MainActor in await self.beginSession() }
                self.pendingBeginTask = task
                self.enqueueSession { await task.value }
            case .release:
                ZFLog.info("Hotkey release")
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
        Task { await preloadEngine() }
    }

    func reloadEngine(useApple: Bool) {
        usingAppleEngine = useApple
        activeEngine = useApple ? appleEngine : whisperEngine
        currentEngineToken = EngineToken()
        engineLabel = useApple ? "Apple Speech" : settingsStore.settings.preferredModel.displayName
        // JOE-2256: supersede any in-flight load for the previous selection.
        if !useApple {
            let store = ModelReadinessStore.shared
            _ = store.select(
                settingsStore.settings.preferredModel,
                allowDownloads: settingsStore.settings.allowModelDownloads,
                localOnly: settingsStore.settings.localOnlyMode)
        }
        ZFLog.info("Engine switched to \(engineLabel)")
    }

    /// JOE-2255: preload through the VERIFIED acquisition lifecycle.
    /// Readiness = verified loadability (manifest+digest), never a non-empty
    /// dir. Local Only mode fails cleanly when a verified model is absent and
    /// download consent is denied; consent is independent of Local Only.
    private func preloadEngine() async {
        guard !usingAppleEngine else { return }
        let model = settingsStore.settings.preferredModel
        isModelLoading = true
        modelDownloadFraction = nil

        let store = ModelReadinessStore.shared
        // JOE-2256: assign the monotonic request id — only this request may
        // publish; a newer selection supersedes it.
        let requestID = store.select(
            model,
            allowDownloads: settingsStore.settings.allowModelDownloads,
            localOnly: settingsStore.settings.localOnlyMode)

        let verified = await store.verifiedReadiness(for: model)
        if verified.state.isReady {
            // Verified cache hit: load directly.
            do {
                try await activeEngine.load(model: model)
                self.isModelLoading = false
                store.publishLoadCompletion(
                    requestID: requestID, model: model,
                    outcome: .ready(model: model))
            } catch {
                ZFLog.error("Model load failed: \(error.localizedDescription)")
                self.isModelLoading = false
                store.publishLoadCompletion(
                    requestID: requestID, model: model,
                    outcome: .failed(model: model, message: error.localizedDescription))
            }
            return
        }

        // No verified model. Explicit download consent gates acquisition
        // (independent of Local Only audio policy).
        let consent = settingsStore.settings.allowModelDownloads
        guard consent else {
            self.isModelLoading = false
            store.markFailed(
                model,
                message: settingsStore.settings.localOnlyMode
                    ? "Model not downloaded and downloads are disabled — enable Model Downloads in Settings."
                    : "Model not downloaded — enable Model Downloads in Settings to acquire it.")
            return
        }

        store.markDownloading(model, progress: nil)
        let result = await store.acquire(model, consent: true)
        guard result.state == .ready else {
            self.isModelLoading = false
            let msg = result.error?.localizedDescription ?? "Model acquisition failed"
            store.publishLoadCompletion(
                requestID: requestID, model: model,
                outcome: .failed(model: model, message: msg))
            return
        }
        do {
            try await activeEngine.load(model: model)
            self.isModelLoading = false
            store.publishLoadCompletion(
                requestID: requestID, model: model,
                outcome: .ready(model: model))
        } catch {
            ZFLog.error("Model load failed: \(error.localizedDescription)")
            self.isModelLoading = false
            store.publishLoadCompletion(
                requestID: requestID, model: model,
                outcome: .failed(model: model, message: error.localizedDescription))
        }
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
