import SwiftUI
import AppKit
import ApplicationServices
import ZephyrFlowCore

@main
struct ZephyrFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            ZephyrMenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }

        // Setup is opened via WindowRouter for full dark chrome control
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var privacyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Prefer dark for any windows we present
        NSApp.appearance = NSAppearance(named: .darkAqua)

        HotkeyService.restoreFnOverrideIfNeededFromPriorLaunch()
        FloatingPanelController.shared.prepare()

        ZFLog.debugEnabled = SettingsStore.shared.settings.debugLogging
        DictationController.shared.start()

        // Screenshot / marketing capture tour (driven by Scripts/capture_screenshots.sh)
        if ProcessInfo.processInfo.environment["ZEPHYRFLOW_UI_TOUR"] == "1" {
            startUITour()
        } else if !SettingsStore.shared.settings.hasCompletedOnboarding {
            // Single clean entry: stepped Setup window handles all permission prompts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                WindowRouter.openOnboarding()
            }
        } else if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                WindowRouter.openOnboarding()
            }
        }

        privacyTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                PrivacyService.shared.refresh()
            }
        }
    }

    /// Opens product surfaces in sequence for `Scripts/capture_screenshots.sh`.
    private func startUITour() {
        let dir = URL(fileURLWithPath: "/tmp/zephyrflow-ui-tour")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stageURL = dir.appendingPathComponent("stage")
        try? "setup".write(to: stageURL, atomically: true, encoding: .utf8)

        // Mark onboarding complete so tour isn't interrupted by first-run gates mid-capture
        SettingsStore.shared.update { $0.hasCompletedOnboarding = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            WindowRouter.openOnboarding()
        }

        // Poll stage file for next surface
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { timer in
            Task { @MainActor in
                let stage = (try? String(contentsOf: stageURL)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                switch stage {
                case "settings":
                    WindowRouter.closeOnboarding()
                    WindowRouter.openSettings()
                    try? "settings-open".write(to: stageURL, atomically: true, encoding: .utf8)
                case "panel":
                    // Keep settings open underneath; show demo listening panel on top
                    DictationController.shared.prepareDemoPanelForScreenshot()
                    try? "panel-open".write(to: stageURL, atomically: true, encoding: .utf8)
                case "done":
                    timer.invalidate()
                    DictationController.shared.clearDemoPanelForScreenshot()
                    WindowRouter.closeOnboarding()
                    // Leave settings closed for a clean quit
                    NSApp.windows.filter { $0.title.contains("Settings") }.forEach { $0.close() }
                default:
                    break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        privacyTimer?.invalidate()
        DictationController.shared.stop()
    }

    /// JOE-2266: macOS asynchronous termination — the process does not exit
    /// until the handshake resolves (or the hard deadline abandons it with a
    /// recovery marker for the next launch).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = DictationController.shared
        sender.reply(toApplicationShouldTerminate: false)
        Task { @MainActor in
            let state = await controller.terminate(deadlineNanosAhead: 3_000_000_000)
            ZFLog.info("termination handshake state=\(state.rawValue) marker=\(state == .abandoned ? "yes" : "none")")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowRouter.openSettings() }
        return true
    }
}
