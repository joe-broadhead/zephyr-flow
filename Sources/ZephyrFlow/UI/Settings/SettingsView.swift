import SwiftUI
import ServiceManagement
import AppKit
import CoreGraphics
import ZephyrFlowCore

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var privacy = PrivacyService.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var controller = DictationController.shared

    @State private var selectedTab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, hotkey, model, privacy, history, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .hotkey: return "Hotkey"
            case .model: return "Model"
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
            case .privacy: return "lock.shield"
            case .history: return "clock"
            case .about: return "info.circle"
            }
        }
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
                if controller.isModelLoading {
                    ProgressView("Loading model…")
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

                Text("Hold the key to talk (or toggle, depending on mode). Release to insert polished text at your cursor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Tips") {
                Text("Fn works like Wispr Flow: hold to talk, release to insert. ZephyrFlow sets the Globe key action to “Do Nothing” while running so the emoji picker doesn’t steal the key. If Fn still misbehaves, use **Right Option** instead.")
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
                        }
                        Spacer()
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
                    Text("Default is Whisper Tiny. Models download once into Application Support and run on-device (Neural Engine).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Model downloads are off — Whisper needs a cached model, or pick Apple Speech.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model")
    }

    // MARK: - Privacy

    private var privacyPane: some View {
        Form {
            Section("Local Only") {
                Toggle("Local Only mode", isOn: binding(\.localOnlyMode))
                Text("Default on. Your voice and transcripts stay on this Mac (no analytics). Optional Whisper model downloads are separate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Allow Whisper model downloads", isOn: binding(\.allowModelDownloads))
                Text("One-time model file download only (default on for Whisper Tiny). Never uploads your audio. Files stay in Application Support and run on-device.")
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
                Text("When on, recent dictations are stored locally in Application Support (plaintext on disk). Logs never store transcript text.")
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
                Text("No analytics, telemetry, or crash reporter. Diagnostic logs record lengths and events only — never transcript text.")
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

            Link("Contribute on GitHub", destination: URL(string: "https://github.com/joe-broadhead/zephyr-flow")!)
            Link("Report an Issue", destination: URL(string: "https://github.com/joe-broadhead/zephyr-flow/issues")!)

            Text("Built for privacy-conscious knowledge workers and developers. Whisper Tiny on-device after a one-time model download; Local Only keeps your audio here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer()
        }
        .navigationTitle("About")
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Non-fatal when running unpackaged from build/
        }
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
                       settings.settings.hotkey.modifiers == CGEventFlags.maskControl.rawValue {
                        return .controlSpace
                    }
                    if settings.settings.hotkey.keyCode == 49,
                       settings.settings.hotkey.modifiers == CGEventFlags.maskAlternate.rawValue {
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
                    config = HotkeyConfig(keyCode: nil, modifiers: 0, displayName: "Right Command (⌘)", specialKey: .rightCommand)
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
