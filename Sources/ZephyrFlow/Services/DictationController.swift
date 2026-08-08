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

    func stop() {
        hotkey.stop()
        levelsTask?.cancel()
        // Close admission and abandon any active session honestly (JOE-2246).
        control.shutdown()
        currentSessionID = nil
        Task {
            await audio.stop()
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
        sessionTargetBundleID = FocusStore.shared.lastBundleID

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
                try await audio.start { [weak self] samples in
                    guard let self else { return }
                    // UI meter from the same PCM Whisper gets (MainActor, no actor hop lag).
                    Task { @MainActor in
                        self.applyMicLevels(samples)
                    }
                    Task { await self.activeEngine.appendAudio(samples) }
                }
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
            let stats = await audio.captureStats()
            ZFLog.info("Capture stats frames16k=\(stats.frames) peakRMS=\(String(format: "%.5f", stats.peakRMS))")
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
            let restored = await FocusStore.shared.restore()
            ZFLog.info("Pre-insert focus restored=\(restored)")

            let result = await insertion.insert(
                trimmed,
                preferPaste: restored,
                mode: settings.settings.insertionMode,
                targetBundleID: sessionTargetBundleID ?? FocusStore.shared.lastBundleID
            )
            ZFLog.info("Insertion result: \(String(describing: result))")
            switch result {
            case .inserted, .pasted:
                _ = control.stage(.targetValidationSucceeded) // resolvingTarget -> inserting
                _ = control.stage(.insertionSucceeded)        // inserting -> completed
            case .copiedToClipboard:
                // Copy-only is an explicit user-visible outcome, not an insert.
                _ = control.stage(.targetValidationSucceeded)
                _ = control.stage(.insertionSucceeded)
            case .failed:
                _ = control.stage(.insertionFailed)
            }

            if settings.settings.saveHistory {
                history.add(
                    HistoryEntry(
                        originalText: final.rawText,
                        finalText: trimmed,
                        duration: final.duration,
                        modelUsed: final.modelUsed
                    )
                )
            }

            switch result {
            case .inserted, .pasted:
                interimText = trimmed
                panelState = .success
                statusMessage = nil
                dismissPanelSoon()
            case .copiedToClipboard:
                interimText = trimmed
                panelState = .success
                statusMessage = "Copied to clipboard — enable Accessibility to auto-insert"
                clearStatusLater()
                dismissPanelSoon()
            case .failed(let msg):
                showError(msg)
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
