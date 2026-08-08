import AppKit
import SwiftUI
import ZephyrFlowCore

struct MenuBarView: View {
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var privacy = PrivacyService.shared
    @ObservedObject private var hotkey = HotkeyService.shared

    var body: some View {
        Group {
            if let status = controller.statusMessage {
                Text(status)
                    .foregroundStyle(.secondary)
            }

            permissionHeader

            Button(isListening ? "Stop & Insert" : "Start Dictation") {
                controller.toggleManualSession()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Setup / Permissions…") {
                WindowRouter.openOnboarding()
            }

            Button("Settings…") { WindowRouter.openSettings() }
            Button("Check for Updates…") {
                WindowRouter.openSettings()
                Task { await UpdateChecker.shared.checkForUpdates() }
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Menu("Flow Style") {
                ForEach(FlowStyle.allCases) { style in
                    Button {
                        settings.update { $0.defaultFlowStyle = style }
                    } label: {
                        Text(
                            settings.settings.defaultFlowStyle == style
                                ? "✓ \(style.displayName)"
                                : style.displayName)
                    }
                }
            }

            Menu("Model") {
                ForEach(ModelIdentifier.allCases) { model in
                    Button {
                        settings.update { $0.preferredModel = model }
                        controller.reloadEngine()
                    } label: {
                        Text(
                            settings.settings.preferredModel == model
                                ? "✓ \(model.displayName)"
                                : model.displayName)
                    }
                }
            }

            Divider()

            Text("Engine: \(controller.engineLabel)")
            Text("Hotkey: \(settings.settings.hotkey.displayName)")
            if settings.settings.localOnlyMode {
                Text("Privacy: Local Only")
            }

            Divider()

            Button("Quit ZephyrFlow") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    @ViewBuilder
    private var permissionHeader: some View {
        if !hotkey.accessibilityTrusted {
            Button("Enable Accessibility…") {
                WindowRouter.openOnboarding()
            }
        } else if !privacy.status.microphone || !privacy.status.speechRecognition {
            Button("Finish Setup…") {
                WindowRouter.openOnboarding()
            }
        } else if !hotkey.tapHealthy {
            Text("Hotkey warming up…")
        } else {
            Text("Fn ready")
        }
    }

    private var isListening: Bool {
        switch controller.panelState {
        case .listening, .processing: return true
        default: return false
        }
    }
}
