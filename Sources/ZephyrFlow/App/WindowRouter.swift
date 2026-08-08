import AppKit
import SwiftUI

/// Single place for opening Settings / Onboarding windows with consistent dark chrome.
@MainActor
enum WindowRouter {
    private static var onboardingWindow: NSWindow?
    private static var settingsWindow: NSWindow?

    static func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Prefer an explicit NSWindow so screenshots / window lists are reliable.
        // (SwiftUI Settings scene windows are often invisible to CGWindowList.)
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView().frame(minWidth: 760, minHeight: 520))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ZephyrFlow Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center()
        applyDarkChrome(to: window)
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window

        // Also try system Settings action for menu parity
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func openOnboarding() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let existing = NSApp.windows.first(where: { $0.title == "ZephyrFlow Setup" }) {
            existing.makeKeyAndOrderFront(nil)
            onboardingWindow = existing
            return
        }

        let view = OnboardingView {
            closeOnboarding()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ZephyrFlow Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        window.setContentSize(NSSize(width: 540, height: 580))
        window.center()
        applyDarkChrome(to: window)
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }

    static func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        // Drop back to menu-bar accessory when no other key windows need us
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let hasKeyUI = NSApp.windows.contains {
                $0.isVisible && $0 != onboardingWindow && $0.title != "" && !($0 is NSPanel)
            }
            if !hasKeyUI {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Call immediately before a system permission sheet so it attaches to our app.
    static func presentForPermissionPrompt() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private static func applyDarkChrome(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        window.titlebarAppearsTransparent = true
    }
}
