import Foundation
import SwiftUI
import Combine
import AppKit
import ZephyrFlowCore

/// Orchestrates hotkey → capture → transcribe → flow → insert.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published var panelState: PanelState = .hidden
    @Published var interimText: String = ""
    @Published var audioLevels: [Float] = Array(repeating: 0.05, count: 24)
    @Published var statusMessage: String?
    @Published var isModelLoading = false
    @Published var modelDownloadFraction: Double?
    @Published var activeFlowStyle: FlowStyle = .clean
    @Published var engineLabel: String = "—"
    /// Bundle id captured at session start for insertion strategies.
    private(set) var sessionTargetBundleID: String?

    private let audio = AudioCapture.shared
    private let insertion = InsertionService.shared
    private let flow = FlowRouter.shared
    private let settings = SettingsStore.shared
    private let history = HistoryStore.shared
    private let privacy = PrivacyService.shared
    private let hotkey = HotkeyService.shared
    private let modelReadiness = ModelReadinessStore.shared

    private var appleEngine = AppleSpeechEngine()
    private var whisperEngine = WhisperKitEngine()
    private var activeEngine: any WhisperEngineProtocol
    private var levelsTask: Task<Void, Never>?
    private var isSessionActive = false
    /// Serializes begin/end/cancel so concurrent hotkey Tasks cannot race.
    private var sessionChain: Task<Void, Never>?
    /// Bumps on each begin; end ignores stale generations.
    private var sessionGeneration: UInt64 = 0
    private var usingAppleEngine = false
    /// Deterministic session control plane (JOE-2246): SessionID, admission,
    /// idempotent edges and exactly-one terminal outcome.
    private var control = SessionControlModel()
    private var currentSessionID: SessionID?
    // JOE-2247 bounded ordered audio: one producer (tap -> channel), one
    // ordered consumer task feeding the selected engine.
    private var audioChannel: BoundedAudioChannel?
    private var audioDeliveryTask: Task<Void, Never>?
    private var audioSequencer = AudioChunkSequencer()
    private var audioDegraded = false
    private var pcmConverter: SessionAudioConverter?
    // JOE-2259: session sensitivity (fail-closed unknown until JOE-2268/2290
    // wire AX target evidence) + in-process review surface.
    private var sessionSensitivity: SessionSensitivity = .unknown
    private var reviewSession: SecureSessionReview?
    private var reviewClearTask: Task<Void, Never>?
    // JOE-2268: immutable per-session AX target evidence + validator service.
    private var targetSnapshot: TargetSnapshot?
    private let targetService = TargetValidationService.shared

    private init() {
        activeEngine = whisperEngine
        usingAppleEngine = false
        activeFlowStyle = SettingsStore.shared.settings.defaultFlowStyle
        configureFlowRouter()
    }

    private func configureFlowRouter() {
        Task {
            await flow.configure(
                backend: { await MainActor.run { SettingsStore.shared.settings.flowBackend } },
                enhancedReady: {
                    await MainActor.run {
                        let s = SettingsStore.shared.settings
                        // Enhanced path is lightweight deterministic rules — ready whenever selected.
                        return s.flowBackend == .enhanced || s.flowBackend == .auto || s.flowBackend.rawValue == "neural"
                    }
                },
                enhanced: EnhancedFlowProcessor.shared
            )
            await EnhancedFlowProcessor.shared.refreshAvailability()
        }
    }

    // MARK: - Lifecycle

    func start() {
        privacy.refresh()
        hotkey.configure(
            hotkey: settings.settings.hotkey,
            mode: settings.settings.listeningMode
        )
        hotkey.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .press:
                ZFLog.info("Hotkey press")
                self.enqueueSession { await self.beginSession() }
            case .release:
                ZFLog.info("Hotkey release")
                self.enqueueSession { await self.endSession() }
            }
        }
        // Detached so SFSpeech/mic permission callbacks (main queue) cannot
        // deadlock with @MainActor awaiting the engine actor.
        Task.detached { [weak self] in
            await self?.preloadEngine()
        }
        // Pre-flight permissions so the first Fn press is never blocked on a dialog
        Task { await self.ensurePermissionsUpFront() }
        ZFLog.info("DictationController started hotkey=\(settings.settings.hotkey.displayName)")
    }

    private func ensurePermissionsUpFront() async {
        privacy.refresh()
        let needUI = !privacy.status.microphone
            || !privacy.status.speechRecognition
            || !privacy.status.accessibility

        guard needUI else {
            ZFLog.info("Permissions already granted")
            return
        }

        // Prefer the stepped Setup window over stacking raw system sheets at launch.
        // System prompts fire one-at-a-time from OnboardingView for clean UX.
        if !settings.settings.hasCompletedOnboarding {
            ZFLog.info("Permission preflight deferred to onboarding")
            return
        }

        ZFLog.info("Missing permissions after onboarding — reopening Setup")
        await MainActor.run {
            WindowRouter.openOnboarding()
        }
    }


    // MARK: Sensitivity + review (JOE-2259)

    /// Session decision: fail-closed unknown until target evidence wiring
    /// (JOE-2268/2290). Until then every session is review-only by policy.
    private func sensitivityDecision() -> SessionSensitivityDecision {
        SessionSensitivityDecision(sensitivity: sessionSensitivity,
                                   source: .noEvidence,
                                   upgradedBeforeInsertion: false)
    }

    /// Review-only surface for secure/unknown sessions. The text lives ONLY
    /// in the SecureSessionReview object (in-process memory); it is never
    /// logged, persisted, or exposed to history/clipboard automatically.
    private func presentSecureReview(_ text: String) {
        guard let sid = currentSessionID else { return }
        let review = SecureSessionReview(sessionID: sid, text: text,
                                         nowNanos: DispatchTime.now().uptimeNanoseconds,
                                         deadlineNanosAhead: 30_000_000_000)
        reviewSession = review
        interimText = text
        panelState = .reviewing
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        reviewClearTask?.cancel()
        reviewClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            await MainActor.run { self.clearReview(reason: .deadlineExpired) }
        }
    }

    /// Explicit, informed user copy for secure/unknown sessions. Consumes the
    /// review content and writes ONLY then; audit stays content-free.
    func copyReviewContent() {
        guard let review = reviewSession else { return }
        let decision = sensitivityDecision()
        guard let taken = review.consumeForExplicitCopy(decision: decision,
                                                        nowNanos: DispatchTime.now().uptimeNanoseconds) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(taken.text, forType: .string)
        ZFLog.info("Secure explicit copy sensitivity=\(taken.audit.sensitivity.rawValue) upgraded=\(taken.audit.upgradedBeforeInsertion)")
        reviewSession = nil
        reviewClearTask?.cancel()
        reviewClearTask = nil
        panelState = .success
    }

    func clearReview(reason: SecureSessionReview.ClearReason) {
        reviewSession?.clear(reason: reason)
        reviewSession = nil
        reviewClearTask?.cancel()
        reviewClearTask = nil
        panelState = .hidden
        interimText = ""
    }

    private var sessionAllowsAutomaticSideEffects: Bool {
        sessionSensitivity.allowsAutomaticSideEffects
    }

    func stop() {
        hotkey.stop()
        levelsTask?.cancel()
        // Close admission and abandon any active session honestly (JOE-2246).
        control.shutdown()
        // JOE-2259: never leave review content resident at termination.
        reviewSession?.clear(reason: .appTerminating)
        reviewSession = nil
        reviewClearTask?.cancel()
        reviewClearTask = nil
        currentSessionID = nil
        Task {
            await audio.stop()
            await audioDeliveryTask?.value
            audioDeliveryTask = nil
            audioChannel = nil
            pcmConverter = nil
            await activeEngine.cancel()
        }
        panelState = .hidden
        isSessionActive = false
    }

    func reloadHotkey() {
        // Full restart so Fn system override + tap config apply cleanly
        hotkey.stop()
        hotkey.configure(
            hotkey: settings.settings.hotkey,
            mode: settings.settings.listeningMode
        )
        hotkey.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .press:
                ZFLog.info("Hotkey press")
                self.enqueueSession { await self.beginSession() }
            case .release:
                ZFLog.info("Hotkey release")
                self.enqueueSession { await self.endSession() }
            }
        }
        ZFLog.info("Hotkey reloaded \(settings.settings.hotkey.displayName)")
    }

    /// FIFO session mutations — prevents press/release Task races.
    private func enqueueSession(_ work: @escaping @MainActor () async -> Void) {
        let previous = sessionChain
        sessionChain = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
    }

    func reloadEngine() {
        Task { await preloadEngine() }
    }

    /// Manual test trigger from menu (toggle semantics).
    /// Stop always finalizes + inserts — never cancels.
    func toggleManualSession() {
        if isSessionActive {
            ZFLog.info("Manual Stop & Insert")
            enqueueSession { await self.endSession() }
        } else {
            ZFLog.info("Manual Start Dictation")
            enqueueSession { await self.beginSession() }
        }
    }

    /// Explicit finalize from panel UI.
    func stopAndInsert() {
        guard isSessionActive else { return }
        ZFLog.info("Panel Stop & Insert")
        enqueueSession { await self.endSession() }
    }

    // MARK: - Engine

    private func preloadEngine() async {
        let snapshot = await MainActor.run { settings.settings }
        let model = snapshot.preferredModel
        let mayDownload = snapshot.mayDownloadModels

        await MainActor.run {
            isModelLoading = true
            modelDownloadFraction = nil
            ZFLog.debugEnabled = snapshot.debugLogging
            ModelReadinessStore.shared.refreshAll()
        }
        defer {
            Task { @MainActor in
                self.isModelLoading = false
                self.modelDownloadFraction = nil
            }
        }

        do {
            if model.isWhisperKit {
                let cached = WhisperModelLocator.readiness(for: model).state.isReady
                if !cached, mayDownload {
                    await MainActor.run {
                        ModelReadinessStore.shared.markDownloading(model, progress: nil)
                        self.modelDownloadFraction = nil
                        self.statusMessage = "Downloading \(model.displayName)…"
                    }
                    ZFLog.info("model_download_start model=\(model.rawValue)")
                }
                let t0 = Date()
                try await whisperEngine.load(model: model, allowDownload: mayDownload)
                let name = await whisperEngine.modelName
                await MainActor.run {
                    self.activeEngine = self.whisperEngine
                    self.usingAppleEngine = false
                    self.engineLabel = name
                    ModelReadinessStore.shared.markReady(model)
                    if !cached, mayDownload {
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        ZFLog.info("model_download_finish model=\(model.rawValue) ms=\(ms)")
                    }
                    self.statusMessage = nil
                }
            } else {
                try await appleEngine.load(model: model)
                let name = await appleEngine.modelName
                await MainActor.run {
                    self.activeEngine = self.appleEngine
                    self.usingAppleEngine = true
                    self.engineLabel = name
                }
            }
            let label = await MainActor.run { self.engineLabel }
            ZFLog.info("Engine loaded: \(label) mayDownload=\(mayDownload)")
        } catch {
            ZFLog.error("Engine load failed: \(error.localizedDescription)")
            if model.isWhisperKit {
                await MainActor.run {
                    ModelReadinessStore.shared.markFailed(model, message: error.localizedDescription)
                }
                ZFLog.info("model_download_fail model=\(model.rawValue)")
            }
            do {
                try await appleEngine.load(model: .appleSpeech)
                let name = await appleEngine.modelName
                await MainActor.run {
                    self.activeEngine = self.appleEngine
                    self.usingAppleEngine = true
                    self.engineLabel = name
                    self.statusMessage = "Using Apple Speech"
                    self.clearStatusLater()
                }
            } catch {
                await MainActor.run {
                    self.engineLabel = "Unavailable"
                    self.statusMessage = error.localizedDescription
                }
                ZFLog.error("Apple Speech fallback failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Session

    private func beginSession() async {
        guard !isSessionActive else {
            ZFLog.info("beginSession ignored — already active")
            return
        }
        // Allocate immutable SessionID before ANY asynchronous preparation.
        guard let sid = control.begin() else {
            ZFLog.info("beginSession rejected by control plane")
            return
        }
        currentSessionID = sid
        ZFLog.info("SessionID allocated \(sid) gen=\(control.generation)")

        privacy.refresh()
        // Fail fast — never await permission dialogs on the hotkey path
        // (that made short Fn holds appear to "do nothing").
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

        // Remember where the user was typing BEFORE any of our UI steals focus
        FocusStore.shared.captureNow()
        // JOE-2268: capture the immutable target snapshot (AX evidence).
        // Missing AX permission => nil => session stays .unknown (fail closed).
        targetSnapshot = targetService.captureSnapshot(
            sessionID: sid,
            nowNanos: DispatchTime.now().uptimeNanoseconds)
        sessionSensitivity = targetSnapshot?.sensitivity.sensitivity ?? .unknown
        // No stale lastBundleID fallback (JOE-2268): the snapshot is the only
        // authority for the insert target; nil means fail-closed review-only.
        sessionTargetBundleID = targetSnapshot?.target.bundleID

        // Surface model download state if Whisper isn't ready yet
        if !usingAppleEngine {
            let model = settings.settings.preferredModel
            let ready = ModelReadinessStore.shared.readiness(for: model)
            if case .downloading = ready.state {
                interimText = ModelReadinessStore.shared.bannerMessage ?? "Downloading model…"
            } else if case .failed(let msg) = ready.state {
                showError(msg)
                return
            }
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        isSessionActive = true
        interimText = ""
        activeFlowStyle = settings.settings.defaultFlowStyle
        panelState = .listening
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        ZFLog.info("Session begin gen=\(generation) usingApple=\(usingAppleEngine)")

        let ready = await activeEngine.isReady
        if !ready {
            await preloadEngine()
        }

        // If release/cancel already ended this session, abort quietly
        // (release during a blocked model load prevents capture — JOE-2246).
        guard isSessionActive, control.isCurrent(sid) else {
            ZFLog.info("Session begin aborted — session superseded")
            await activeEngine.cancel()
            return
        }
        _ = control.stage(.readyToCapture)

        do {
            let localOnly = settings.settings.localOnlyMode
            try await activeEngine.startStreaming(localOnly: localOnly) { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.sessionGeneration == generation,
                          let sid = self.currentSessionID, self.control.isCurrent(sid) else { return }
                    self.interimText = partial.text
                }
            }

            guard isSessionActive, control.isCurrent(sid) else {
                await activeEngine.cancel()
                return
            }

            if usingAppleEngine {
                startAppleLevelsPolling()
            } else {
                // Bounded, ordered audio channel (JOE-2247): capacity 256
                // chunks covers a ~21 s tail at a 48 kHz / 4096-frame tap
                // with no consumer stall; bounded memory regardless of
                // recording length.
                let channel = BoundedAudioChannel(sessionID: sid, capacity: 256)
                audioChannel = channel
                audioSequencer = AudioChunkSequencer()
                audioDegraded = false
                let converter = SessionAudioConverter()
                pcmConverter = converter
                let engine = activeEngine
                audioDeliveryTask = Task { [weak self] in
                    for await chunk in channel.chunks {
                        guard let self else { return }
                        // Reordered/late chunks can never be appended: counted,
                        // skipped, and the session is marked degraded.
                        if chunk.sequence < self.audioSequencer.nextExpected {
                            self.audioDegraded = true
                            continue
                        }
                        self.audioSequencer.accept(chunk)
                        guard let mono = converter.convert(chunk) else { continue }
                        await engine.appendAudio(mono)
                    }
                }
                try await audio.start(sessionID: sid, channel: channel)
                startAudioLevelsPolling()
            }

            // Keep focus in the user's app while they speak
            await FocusStore.shared.restore()
        } catch {
            ZFLog.error("Session start failed: \(error.localizedDescription)")
            _ = control.stage(.captureFailed)
            if sessionGeneration == generation {
                isSessionActive = false
                let msg = error.localizedDescription
                showError(msg)
                if msg.localizedCaseInsensitiveContains("Dictation is turned off") {
                    PrivacyService.shared.openDictationSettings()
                }
            }
            await audio.stop()
            await activeEngine.cancel()
        }
    }

    private func endSession() async {
        guard isSessionActive else {
            ZFLog.info("endSession ignored — not active")
            return
        }
        guard let sid = currentSessionID, control.isCurrent(sid) else {
            ZFLog.info("endSession ignored — stale/terminal session")
            return
        }
        let generation = sessionGeneration
        isSessionActive = false
        levelsTask?.cancel()
        panelState = .processing
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        // Immediate control effect: stop is not queued behind stage work.
        let effect = control.stop()
        if effect == .idempotentNoop || effect == .illegal {
            ZFLog.info("endSession control no-op state=\(control.state.rawValue)")
        }
        ZFLog.info("Session end gen=\(generation) — finalizing")

        await audio.stop()
        if !usingAppleEngine {
            // Drain the bounded ordered channel into the engine BEFORE
            // finalize so delivery order is exact, then surface degradation.
            await audioDeliveryTask?.value
            let channel = audioChannel
            let stats = await audio.captureStats()
            let seqDegraded = audioSequencer.isDegraded
            let channelDegraded = channel?.isDegraded ?? false
            ZFLog.info("Capture stats enqueued=\(stats.enqueued) overflowDropped=\(stats.overflowDropped) wrongSession=\(stats.wrongSessionRejected) peakRMS=\(String(format: "%.5f", stats.peakRMS))")
            if seqDegraded || channelDegraded {
                // Overflow/desync/cross-session means the capture is not a
                // complete session: fail closed instead of ordinary success.
                ZFLog.info("Audio capture degraded — discard (overflow=\(stats.overflowDropped) reject=\(stats.wrongSessionRejected))")
                _ = control.stage(.captureFailed)
                showError("Audio capture degraded — partial session discarded")
                await activeEngine.cancel()
                audioDeliveryTask = nil
                audioChannel = nil
                pcmConverter = nil
                return
            }
        }

        do {
            let final = try await activeEngine.stopAndFinalize()
            // Discard if a newer session already started
            guard sessionGeneration == generation, control.isCurrent(sid) else {
                ZFLog.info("endSession discarded — stale generation")
                return
            }
            _ = control.stage(.drainFinished)   // draining -> transcribing
            _ = control.stage(.transcriptionFinished) // transcribing -> transforming

            // JOE-2259: secure/unknown sessions never run structural/semantic
            // Flow and never auto-insert/clipboard/history. Fail-closed: they
            // are review-only with an explicit user copy. (JOE-2268 validates
            // normal sessions transactionally right before insertion.)
            if !sessionAllowsAutomaticSideEffects {
                _ = control.stage(.transformationFinished) // transforming -> resolvingTarget
                _ = control.stage(.targetSecure)           // resolvingTarget -> secureTarget (terminal)
                let conservative = await flow.process(final.rawText, style: .clean)
                let reviewText = conservative.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reviewText.isEmpty else {
                    showError("No speech detected — try again")
                    ZFLog.info("Empty transcription")
                    return
                }
                panelState = .processing
                FloatingPanelController.shared.hide()
                presentSecureReview(reviewText)
                ZFLog.info("Sensitive session review-only len=\(reviewText.count) outcome=secureTarget")
                return
            }

            let style = activeFlowStyle
            let flowT0 = Date()
            let processed = await flow.process(final.rawText, style: style)
            let flowMs = Int(Date().timeIntervalSince(flowT0) * 1000)
            // Lengths only — never log transcript body
            ZFLog.info(
                "Processed len=\(processed.count) raw len=\(final.rawText.count) flowMs=\(flowMs) style=\(style.rawValue) backend=\(settings.settings.flowBackend.rawValue)"
            )

            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                showError("No speech detected — try again")
                ZFLog.info("Empty transcription")
                return
            }

            // Stale session check after flow (may have taken up to the enhanced timeout)
            guard sessionGeneration == generation, control.isCurrent(sid) else {
                ZFLog.info("endSession discarded after flow — stale generation")
                return
            }
            _ = control.stage(.transformationFinished) // transforming -> resolvingTarget

            panelState = .processing
            FloatingPanelController.shared.hide()
            NSApp.deactivate()

            // JOE-2268: transactional target validation — prove the current
            // destination is the captured intended target before any write.
            guard let snapshot = targetSnapshot, snapshot.sessionID == sid else {
                // No captured snapshot (AX unavailable at session start, or
                // capture raced): fail closed to unknown — review-only, no
                // automatic side effects, explicit copy only.
                ZFLog.info("target validation skipped — no snapshot, review-only")
                _ = control.stage(.targetUnknown)
                presentSecureReview(trimmed)
                return
            }

            var validation = TargetValidationSession(
                sessionID: sid,
                snapshot: snapshot,
                deadlineNanosAhead: 2_000_000_000)
            validation.start(nowNanos: DispatchTime.now().uptimeNanoseconds)

            // Bounded, observable restore (TargetRestoreMonitor): activates the
            // captured app and polls frontmost state — never a blind sleep.
            let monitor = await targetService.restoreToCapturedTarget(snapshot: snapshot)
            let restored = monitor.status == .restored
            ZFLog.info("target restore status=\(monitor.status.rawValue) attempts=\(monitor.attempts) restored=\(restored)")

            // Re-resolve the current focused AX context immediately before any
            // side effect and decide the controlled outcome (content-free).
            let context = targetService.currentContext(
                nowNanos: DispatchTime.now().uptimeNanoseconds)
            let outcome = validation.validate(
                context: context,
                nowNanos: DispatchTime.now().uptimeNanoseconds)
            ZFLog.info("target validation outcome=\(outcome.rawValue) reason=\(validation.reason?.rawValue ?? "nil")")

            switch outcome {
            case .validated:
                // Zero transcript-bearing side effects happened before this.
                _ = control.stage(.targetValidationSucceeded) // resolvingTarget -> inserting
                let result = await insertion.insert(
                    trimmed,
                    preferPaste: restored,
                    mode: settings.settings.insertionMode,
                    targetBundleID: snapshot.target.bundleID,
                    sensitivity: validation.effectiveSensitivity
                )
                ZFLog.info("Insertion result: \(String(describing: result))")
                switch result {
                case .verifiedInserted:
                    _ = control.stage(.insertionSucceeded)    // inserting -> completed
                case .explicitlyCopiedByUser:
                    // Explicit user-facing copy is a completed action, not an
                    // unverified insertion (JOE-2269).
                    _ = control.stage(.insertionSucceeded)
                case .eventPostedUnverified:
                    // Paste was posted but the target never confirmed: this is
                    // NOT a verified insertion — honest terminal outcome.
                    _ = control.stage(.insertionSucceeded)
                case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
                     .notEditable, .clipboardNotRestoredBecauseChanged,
                     .clipboardRestoreFailed, .deadlineExceeded, .cancelled,
                     .failed:
                    _ = control.stage(.insertionFailed)
                }

                // JOE-2259/2269: history is a transcript-bearing mutation; the
                // central outcome policy decides retention (never for
                // unverified/uncertain outcomes), combined with sensitivity.
                if settings.settings.saveHistory,
                   SensitiveSessionPolicy.historyWriteAllowed(sensitivity: validation.effectiveSensitivity),
                   result.permitsHistoryRetention {
                    history.add(
                        HistoryEntry(
                            originalText: final.rawText,
                            finalText: trimmed,
                            duration: final.duration,
                            modelUsed: final.modelUsed
                        )
                    )
                } else if settings.settings.saveHistory {
                    ZFLog.info("History skipped — outcome=\(String(describing: result)) sens=\(validation.effectiveSensitivity.rawValue)")
                }

                // Central outcome policy (JOE-2269): green success UI, panel
                // dismissal and status text all derive from the outcome.
                switch result {
                case .verifiedInserted:
                    interimText = trimmed
                    panelState = .success
                    statusMessage = nil
                    dismissPanelSoon()
                case .explicitlyCopiedByUser:
                    interimText = trimmed
                    panelState = .success
                    statusMessage = result.userFacingMessage
                    clearStatusLater()
                    dismissPanelSoon()
                case .eventPostedUnverified:
                    // Never present unverified posting as green success.
                    interimText = trimmed
                    panelState = .success
                    statusMessage = result.userFacingMessage
                    clearStatusLater()
                    dismissPanelSoon()
                case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
                     .notEditable, .clipboardNotRestoredBecauseChanged,
                     .clipboardRestoreFailed, .deadlineExceeded, .cancelled,
                     .failed(let msg):
                    showError(msg)
                }
            case .targetChanged, .targetGone, .notEditable:
                // Controlled abort: no write, honest terminal outcome.
                _ = control.stage(.targetChanged)
                showError("Target changed — insertion cancelled")
                ZFLog.info("insertion cancelled outcome=\(outcome.rawValue)")
            case .targetUnknown:
                _ = control.stage(.targetUnknown)
                // Fail closed: unknown target — review-only with explicit copy.
                presentSecureReview(trimmed)
            case .secureTarget:
                _ = control.stage(.targetSecure)
                // Fail closed: secure reclassification — review-only, no
                // paste/AX/history, explicit copy only.
                presentSecureReview(trimmed)
            case .deadlineExceeded:
                _ = control.stage(.deadlineViolated)
                showError("Target validation timed out")
            }

        } catch {
            ZFLog.error("Session finalize failed: \(error.localizedDescription)")
            if sessionGeneration == generation {
                let msg = error.localizedDescription
                showError(msg)
                if msg.localizedCaseInsensitiveContains("Dictation is turned off") {
                    PrivacyService.shared.openDictationSettings()
                }
            }
            await activeEngine.cancel()
        }
    }

    func cancelSession() {
        enqueueSession {
            self.sessionGeneration &+= 1
            _ = self.control.cancel()
            self.currentSessionID = nil
            self.isSessionActive = false
            self.levelsTask?.cancel()
            await self.audio.stop()
            await self.audioDeliveryTask?.value
            self.audioDeliveryTask = nil
            self.audioChannel = nil
            self.pcmConverter = nil
            self.reviewSession?.clear(reason: .sessionCancelled)
            self.reviewSession = nil
            self.reviewClearTask?.cancel()
            self.reviewClearTask = nil
            await self.activeEngine.cancel()
            self.panelState = .hidden
            self.interimText = ""
            FloatingPanelController.shared.hide()
            self.hotkey.resetToggle()
            ZFLog.info("Session cancelled")
        }
    }

    func applyQuickAction(_ style: FlowStyle) {
        activeFlowStyle = style
    }

    /// Marketing / docs screenshots only — does not start audio.
    func prepareDemoPanelForScreenshot() {
        interimText = "Private voice-to-text at your cursor…"
        audioLevels = (0..<24).map { i in
            Float(0.15 + 0.55 * abs(sin(Double(i) * 0.45)))
        }
        activeFlowStyle = settings.settings.defaultFlowStyle
        panelState = .listening
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        FloatingPanelController.shared.resizeToFit()
    }

    func clearDemoPanelForScreenshot() {
        panelState = .hidden
        interimText = ""
        FloatingPanelController.shared.hide()
    }

    // MARK: - Levels

    /// Update orb waveform from mono PCM (already on MainActor).
    private func applyMicLevels(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        let step = max(1, samples.count / 128)
        var n = 0
        var i = 0
        while i < samples.count {
            let s = samples[i]
            sum += s * s
            n += 1
            i += step
        }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        let level = min(1, max(0.05, rms * 18))
        var next = audioLevels
        if next.count != 24 { next = Array(repeating: 0.08, count: 24) }
        next.removeFirst()
        next.append(level)
        let j = next.count - 1
        if j >= 1 {
            next[j] = next[j] * 0.5 + next[j - 1] * 0.5
        }
        audioLevels = next
    }

    private func startAudioLevelsPolling() {
        levelsTask?.cancel()
        levelsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let levels = await self.audio.levels()
                await MainActor.run {
                    // Backup path if callback levels are quiet/stuck
                    if levels.contains(where: { $0 > 0.08 }) {
                        self.audioLevels = levels
                    }
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func startAppleLevelsPolling() {
        levelsTask?.cancel()
        levelsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let levels = await self.appleEngine.levels()
                await MainActor.run { self.audioLevels = levels }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: - UI helpers

    private func showError(_ message: String) {
        let generation = sessionGeneration
        panelState = .error(message)
        statusMessage = message
        FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard sessionGeneration == generation else { return }
            if case .error = panelState {
                panelState = .hidden
                FloatingPanelController.shared.hide()
            }
        }
    }

    private func dismissPanelSoon() {
        let generation = sessionGeneration
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard sessionGeneration == generation else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                panelState = .hidden
                interimText = ""
            }
            FloatingPanelController.shared.hide()
        }
    }

    private func clearStatusLater() {
        let generation = sessionGeneration
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard sessionGeneration == generation else { return }
            statusMessage = nil
        }
    }
}

import ApplicationServices
