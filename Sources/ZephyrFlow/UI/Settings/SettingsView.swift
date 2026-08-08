import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI
import ZephyrFlowCore

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var privacy = PrivacyService.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var modelReadiness = ModelReadinessStore.shared
    @ObservedObject private var updates = UpdateChecker.shared

    @State private var selectedTab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, hotkey, model, flow, privacy, history, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .hotkey: return "Hotkey"
            case .model: return "Model"
            case .flow: return "Flow"
            case .privacy: return "Privacy"
            case .history: return "History"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .hotkey: return "keyboard"
            case .model: return "cpu"
            case .flow: return "wind"
            case .privacy: return "lock.shield"
            case .history: return "clock"
            case .about: return "info.circle"
            }
        }
    }

    @State private var copyOnlyOverridesText = ""

    private var languageBinding: Binding<SupportedLanguage> {
        Binding(
            get: { settings.settings.language },
            set: { newValue in settings.update { $0.language = newValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(180)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedTab {
                case .general: generalPane
                case .hotkey: hotkeyPane
                case .model: modelPane
                case .flow: flowPane
                case .privacy: privacyPane
                case .history: historyPane
                case .about: aboutPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 480)
        .zephyrDarkChrome()
        .onAppear {
            privacy.refresh()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            copyOnlyOverridesText = settings.settings.copyOnlyOverrideBundleIDs.joined(separator: ", ")
        }
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section("Dictation") {
                Picker("Listening mode", selection: binding(\.listeningMode)) {
                    ForEach(ListeningMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.settings.listeningMode) { _, _ in
                    controller.reloadHotkey()
                }

                Picker("Default flow style", selection: binding(\.defaultFlowStyle)) {
                    ForEach(FlowStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.systemImage).tag(style)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: binding(\.launchAtLogin))
                    .onChange(of: settings.settings.launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }

            Section("Engine") {
                LabeledContent("Active engine", value: controller.engineLabel)
                // JOE-2254: validated language selection (auto + supported
                // BCP-47 matrix); affects the NEXT session, never the active one.
                Picker("Language", selection: languageBinding) {
                    ForEach(SupportedLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text(
                    "Auto-detect uses the engine's detection. Fixed languages are preflighted for on-device support before capture (Local Only never falls back to network)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if controller.isModelLoading {
                    ProgressView("Loading model…")
                }
                if let banner = modelReadiness.bannerMessage {
                    Text(banner)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Insertion") {
                Picker("Mode", selection: binding(\.insertionMode)) {
                    ForEach(InsertionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Automatic picks paste vs Accessibility per app. Copy only never types keystrokes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Panel") {
                Button("Reset panel position") {
                    settings.update {
                        $0.panelOriginX = nil
                        $0.panelOriginY = nil
                        $0.panelPositionLocked = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    // MARK: - Hotkey

    private var hotkeyPane: some View {
        Form {
            Section("Global Hotkey") {
                Picker("Hotkey", selection: hotkeySelection) {
                    Text("Fn").tag(HotkeyChoice.fn)
                    Text("Right Option (⌥)").tag(HotkeyChoice.rightOption)
                    Text("Right Command (⌘)").tag(HotkeyChoice.rightCommand)
                    Text("Control + Space").tag(HotkeyChoice.controlSpace)
                    Text("Option + Space").tag(HotkeyChoice.optionSpace)
                }
                .onChange(of: settings.settings.hotkey) { _, _ in
                    controller.reloadHotkey()
                }

                Text(
                    "Hold the key to talk (or toggle, depending on mode). Release to insert polished text at your cursor."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Tips") {
                Text(
                    "Fn works like Wispr Flow: hold to talk, release to insert. ZephyrFlow sets the Globe key action to “Do Nothing” while running so the emoji picker doesn’t steal the key. If Fn still misbehaves, use **Right Option** instead."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("Requires Accessibility permission. After enabling it, quit and reopen ZephyrFlow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hotkey")
    }

    // MARK: - Model

    private var modelPane: some View {
        Form {
            Section("Transcription Model") {
                ForEach(ModelIdentifier.allCases) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.headline)
                            Text(model.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(readinessLabel(for: model))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        readinessIcon(for: model)
                        if settings.settings.preferredModel == model {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectModel(model)
                    }
                    .padding(.vertical, 4)
                    .opacity(modelBlocked(model) ? 0.45 : 1)
                }
            }

            Section {
                if settings.settings.allowModelDownloads {
                    Text(
                        "Default is Whisper Tiny. Models download once and run on-device. Status reflects local cache."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Model downloads are off — Whisper needs a cached model, or pick Apple Speech.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh model status") {
                    modelReadiness.refreshAll()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model")
        .onAppear { modelReadiness.refreshAll() }
    }

    private var flowPane: some View {
        Form {
            Section("Cleanup backend") {
                Picker("Flow backend", selection: binding(\.flowBackend)) {
                    ForEach(FlowBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(
                    "Classic is instant regex (default). Enhanced adds extra on-device rule cleanup for Professional / Bullets / Summary (not a language model). Clean and Raw always stay Classic."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section("Default style") {
                Picker("Style", selection: binding(\.defaultFlowStyle)) {
                    ForEach(FlowStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.systemImage).tag(style)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Flow")
    }

    // MARK: - Privacy

    private var privacyPane: some View {
        Form {
            Section("Local Only") {
                Toggle("Local Only mode", isOn: binding(\.localOnlyMode))
                Text(
                    "Default on. Your voice and transcripts stay on this Mac (no analytics). Optional Whisper model downloads are separate."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Toggle("Allow Whisper model downloads", isOn: binding(\.allowModelDownloads))
                Text(
                    "One-time model file download only (default on for Whisper Tiny). Never uploads your audio. Files stay in Application Support and run on-device."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                statusRow("Microphone", ok: privacy.status.microphone) {
                    privacy.openMicrophoneSettings()
                }
                statusRow("Accessibility", ok: privacy.status.accessibility) {
                    privacy.openAccessibilitySettings()
                }
                statusRow("Speech Recognition", ok: privacy.status.speechRecognition) {
                    privacy.openSpeechSettings()
                }
                Button("Refresh status") { privacy.refresh() }
            }

            Section("History") {
                Toggle("Save transcription history", isOn: binding(\.saveHistory))
                // JOE-2262: honest defense-in-depth wording — encrypted at
                // rest with a per-installation Keychain key; metadata (id,
                // timestamp, model) remains visible for the list UI.
                Text(
                    "When on, recent dictations are stored locally in Application Support, encrypted at rest (AES-256-GCM) with a per-installation Keychain key. Metadata for the list UI stays visible; transcript bodies are sealed. This is app-level protection, not a substitute for FileVault."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Button("Clear local history", role: .destructive) {
                    history.clear()
                }
            }

            Section("Diagnostics") {
                Toggle("Debug logging", isOn: binding(\.debugLogging))
                    .onChange(of: settings.settings.debugLogging) { _, on in
                        ZFLog.debugEnabled = on
                    }
                Text("Writes extra hotkey/engine detail to ~/Library/Logs/ZephyrFlow/ (local only, rotated).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Reset system Fn / Globe key preference") {
                    HotkeyService.shared.resetSystemFnPreferenceNow()
                }
            }

            Section("Audit") {
                Text(
                    "No analytics, telemetry, or crash reporter. Diagnostic logs record lengths and events only — never transcript text."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
        .onAppear {
            privacy.refresh()
            ZFLog.debugEnabled = settings.settings.debugLogging
        }
    }

    // MARK: - History

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History").font(.title2.bold())
                Spacer()
                Button("Clear All", role: .destructive) {
                    history.clear()
                }
                .disabled(history.entries.isEmpty)
            }

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No transcriptions yet",
                    systemImage: "text.bubble",
                    description: Text("Your recent dictations will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.finalText)
                                .lineLimit(3)
                            HStack {
                                Text(entry.timestamp, style: .relative)
                                Text("·")
                                Text(String(format: "%.1fs", entry.duration))
                                Text("·")
                                Text(entry.modelUsed)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.finalText, forType: .string)
                            }
                            Button("Delete", role: .destructive) {
                                history.delete(entry.id)
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx {
                            history.delete(history.entries[i].id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZephyrMarkBadge(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ZephyrFlow").font(.title.bold())
                    Text("Private voice-to-text that appears at your cursor")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Version", value: ZephyrFlowConstants.version)
            LabeledContent("License", value: "MIT")
            LabeledContent("Bundle ID", value: "dev.zephyrflow.app")

            GroupBox("Updates") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(updateStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            Task { await updates.checkForUpdates() }
                        } label: {
                            if case .checking = updates.status {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking…")
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .disabled(
                            {
                                if case .checking = updates.status { return true }
                                return false
                            }())

                        if case .updateAvailable = updates.status {
                            Button("Download") {
                                updates.openDownload()
                            }
                            .keyboardShortcut(.defaultAction)
                            Button("Release Notes") {
                                updates.openReleasePage()
                            }
                        }
                    }

                    Text("Checks GitHub Releases only when you click the button. No background update pings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Link("Contribute on GitHub", destination: ZephyrFlowConstants.githubURL)
            Link("Report an Issue", destination: URL(string: "https://github.com/joe-broadhead/zephyr-flow/issues")!)
            Link("All Releases", destination: ZephyrFlowConstants.releasesURL)

            Text(
                "Built for privacy-conscious knowledge workers and developers. Whisper Tiny on-device after a one-time model download; Local Only keeps your audio here."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            Spacer()
        }
        .navigationTitle("About")
    }

    private var updateStatusText: String {
        switch updates.status {
        case .idle:
            return "Current version \(ZephyrFlowConstants.version)."
        case .checking:
            return "Contacting GitHub Releases…"
        case .upToDate(let current):
            return "You’re on the latest version (\(current))."
        case .updateAvailable(let latest, let notes, _, _):
            if let notes, !notes.isEmpty {
                let preview =
                    notes
                    .components(separatedBy: .newlines)
                    .prefix(4)
                    .joined(separator: "\n")
                return "Version \(latest) is available.\n\n\(preview)"
            }
            return "Version \(latest) is available."
        case .failed(let message):
            return "Couldn’t check for updates: \(message)"
        }
    }

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { settings.settings[keyPath: keyPath] },
            set: { newValue in
                settings.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func modelBlocked(_ model: ModelIdentifier) -> Bool {
        model.isWhisperKit && !settings.settings.allowModelDownloads
    }

    private func readinessLabel(for model: ModelIdentifier) -> String {
        let r = modelReadiness.readiness(for: model)
        switch r.state {
        case .notApplicable: return "Built-in"
        case .missing: return "Not downloaded"
        case .downloading:
            return "Downloading…"
        case .ready:
            if let b = r.bytesOnDisk, b > 0 {
                return "Ready · \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))"
            }
            return "Ready"
        case .queued: return "Queued…"
        case .verifying: return "Verifying…"
        case .cancelled: return "Cancelled"
        case .quarantined: return "Quarantined — corrupt content"
        case .failed(let m): return "Failed — \(m)"
        }
    }

    @ViewBuilder
    private func readinessIcon(for model: ModelIdentifier) -> some View {
        switch modelReadiness.readiness(for: model).state {
        case .ready:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .missing:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .notApplicable:
            EmptyView()
        case .queued, .verifying:
            ProgressView().controlSize(.small)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .quarantined:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func selectModel(_ model: ModelIdentifier) {
        settings.update { $0.preferredModel = model }
        controller.reloadEngine()
    }

    private func statusRow(_ title: String, ok: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(ok ? "Granted" : "Missing")
                .foregroundStyle(.secondary)
            if !ok {
                Button("Open Settings", action: open)
            }
        }
    }

    @State private var launchLoginPending = false
    @State private var launchLoginError: String?

    /// JOE-2290: transactional toggle — pending -> external change -> verify ->
    /// commit settings only on convergence; roll back + persistent error on
    /// failure; approval/not-found states explain availability.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard !launchLoginPending else { return }
        launchLoginPending = true
        launchLoginError = nil
        Task { @MainActor in
            let state = await LaunchAtLoginService.shared.apply(enabled: enabled)
            launchLoginPending = false
            switch state {
            case .applied:
                // Converged with verified system status — commit settings.
                settings.update { $0.launchAtLogin = enabled }
                launchLoginError = nil
            case .rolledBack:
                // Failed: settings JSON keeps the VERIFIED system state.
                let status = LaunchAtLoginService.shared.authoritativeStatus()
                settings.update { $0.launchAtLogin = (status == .registered) }
                launchLoginError =
                    LaunchAtLoginService.shared.availabilityMessage()
                    ?? "Could not change Launch at Login. Open Login Items settings to fix."
            default:
                break
            }
        }
    }

    private func openLoginItemsSettings() {
        LaunchAtLoginService.shared.openLoginItemsSettings()
    }

    // Hotkey picker bridge
    private enum HotkeyChoice: Hashable {
        case fn, rightOption, rightCommand, controlSpace, optionSpace
    }

    private var hotkeySelection: Binding<HotkeyChoice> {
        Binding(
            get: {
                switch settings.settings.hotkey.specialKey {
                case .fn: return .fn
                case .rightOption: return .rightOption
                case .rightCommand: return .rightCommand
                case .rightControl:
                    return .fn
                case .none:
                    if settings.settings.hotkey.keyCode == 49,
                        settings.settings.hotkey.modifiers == CGEventFlags.maskControl.rawValue
                    {
                        return .controlSpace
                    }
                    if settings.settings.hotkey.keyCode == 49,
                        settings.settings.hotkey.modifiers == CGEventFlags.maskAlternate.rawValue
                    {
                        return .optionSpace
                    }
                    return .fn
                }
            },
            set: { choice in
                let config: HotkeyConfig
                switch choice {
                case .fn:
                    config = .default
                case .rightOption:
                    config = .rightOption
                case .rightCommand:
                    config = HotkeyConfig(
                        keyCode: nil, modifiers: 0, displayName: "Right Command (⌘)", specialKey: .rightCommand)
                case .controlSpace:
                    config = HotkeyConfig(
                        keyCode: 49,
                        modifiers: UInt(CGEventFlags.maskControl.rawValue),
                        displayName: "Control + Space",
                        specialKey: nil
                    )
                case .optionSpace:
                    config = HotkeyConfig(
                        keyCode: 49,
                        modifiers: UInt(CGEventFlags.maskAlternate.rawValue),
                        displayName: "Option + Space",
                        specialKey: nil
                    )
                }
                settings.update { $0.hotkey = config }
            }
        )
    }
}
