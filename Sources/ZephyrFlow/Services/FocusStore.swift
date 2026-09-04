import AppKit
import ApplicationServices

/// Remembers the last user-facing app/focus so we can insert there after
/// the floating panel or menu bar steals interaction.
@MainActor
final class FocusStore {
    static let shared = FocusStore()

    private(set) var lastBundleID: String?
    private(set) var lastPID: pid_t = 0
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "dev.zephyrflow.app"

    private init() {
        // Track whatever the user is actually working in
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.noteActivation(app)
            }
        }
        // Seed
        if let front = NSWorkspace.shared.frontmostApplication {
            noteActivation(front)
        }
    }

    private func noteActivation(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier, !isOwnOrIgnored(bid) else { return }
        lastBundleID = bid
        lastPID = app.processIdentifier
    }

    /// Capture right before a dictation session UI appears.
    func captureNow() {
        if let front = NSWorkspace.shared.frontmostApplication {
            noteActivation(front)
        }
        // If frontmost is us / never seeded, pick the most recently active user app.
        if lastBundleID == nil {
            seedFromRunningApps()
        }
        // AX: app owning the focused element (best signal for insert target)
        if lastBundleID == nil || isOwnOrIgnored(lastBundleID) {
            if let axApp = focusedApplication() {
                noteActivation(axApp)
            }
        }
        ZFLog.info("Focus captured target=\(lastBundleID ?? "nil") pid=\(lastPID)")
    }

    private func isOwnOrIgnored(_ bid: String?) -> Bool {
        guard let bid else { return true }
        if bid == ownBundleID { return true }
        return ignoredBundleIDs.contains(bid)
    }

    private var ignoredBundleIDs: Set<String> {
        [
            "com.apple.loginwindow",
            "com.apple.SecurityAgent",
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.Spotlight",
        ]
    }

    private func seedFromRunningApps() {
        // Prefer regular apps the user can type into (not background-only).
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { ($0.bundleIdentifier.map { !isOwnOrIgnored($0) }) ?? false }
        // Frontmost among regular apps if any is active
        if let active = candidates.first(where: { $0.isActive }) {
            noteActivation(active)
            return
        }
        // Otherwise leave unset — restore will no-op and paste may still work if user refocuses
    }

    private func focusedApplication() -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedApplicationAttribute as CFString,
                &focusedRef
            ) == .success,
            let focused = focusedRef,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Bring the user's app back and give it a moment to take focus.
    @discardableResult
    func restore() async -> Bool {
        guard lastPID != 0 || lastBundleID != nil else {
            ZFLog.info("Focus restore: nothing saved")
            return false
        }

        let app: NSRunningApplication? = {
            if lastPID != 0 {
                return NSRunningApplication(processIdentifier: lastPID)
                    ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == lastBundleID }
            }
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == lastBundleID }
        }()

        guard let app, !app.isTerminated else {
            ZFLog.info("Focus restore: target app gone")
            return false
        }

        // Don't leave ZephyrFlow as key window
        for window in NSApp.windows {
            if window.isKeyWindow || window.isMainWindow {
                window.resignKey()
                window.orderBack(nil)
            }
        }
        NSApp.deactivate()

        let ok = app.activate(options: [])
        ZFLog.info("Focus restore activate=\(ok) app=\(app.bundleIdentifier ?? "?")")

        // Allow the target app to become frontmost + restore its focused field
        try? await Task.sleep(nanoseconds: 120_000_000)
        return ok
    }
}
