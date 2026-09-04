import AppKit
import ApplicationServices
import Darwin
import ZephyrFlowCore

// MARK: JOE-2268 — AX-backed target capture + revalidation service.
//
// All content-free: process/window/element identity and capability flags only;
// never field text or document titles. Rules enforced here:
// 1. Snapshot only the focused, user-facing target (never Zephyr itself or
//    ignored system processes).
// 2. No Accessibility permission => capture returns nil => controller treats
//    the session as `unknown` (fail closed, no automatic side effects).
// 3. Restore uses the bounded, observable TargetRestoreMonitor (JOE-2268),
//    never a blind sleep.
// 4. Identity is immutable per session; re-resolution happens immediately
//    before insertion (TargetValidationSession), also content-free.

@MainActor
final class TargetValidationService: TargetValidationProviding {
    static let shared = TargetValidationService()

    private let ownBundleID = Bundle.main.bundleIdentifier ?? "dev.zephyrflow.app"
    private let textLikeRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField",
        "AXTextView", "AXSearchField",
    ]

    private init() {}

    var isAxTrusted: Bool { AXIsProcessTrusted() }

    // MARK: capture (session start)

    func captureSnapshot(sessionID: SessionID, nowNanos: UInt64) async -> TargetSnapshot? {
        guard isAxTrusted else {
            ZFLog.info("revalidate: capture skipped (AX untrusted) sid=\(sessionID.token)")
            return nil
        }
        guard let app = focusedAXApplication() else {
            ZFLog.info("revalidate: no focused target")
            return nil
        }
        let pid = app.processIdentifier
        guard let bundle = app.bundleIdentifier, !isIgnorable(bundleID: bundle) else {
            ZFLog.info("revalidate: target ignored pid=\(pid)")
            return nil
        }
        let element = focusedElement(of: app)
        let role = element.flatMap { attr($0, kAXRoleAttribute) }
        let subrole = element.flatMap { attr($0, kAXSubroleAttribute) }
        let identifier = element.flatMap { attr($0, kAXIdentifierAttribute) }
        let settable = element.map { self.axSettable($0) } ?? false
        let editable = element.map { textLikeRoles.contains(attr($0, kAXRoleAttribute) ?? "") } ?? false
        let enabled = element.map { axBool($0, kAXEnabledAttribute) } ?? false

        let isSecure = role == "AXSecureTextField"
        let sensitivity: SensitivityAssessment
        if isSecure {
            sensitivity = SensitivityAssessment(
                sensitivity: .secure,
                source: .accessibilityRole,
                capturedAtNanos: nowNanos)
        } else if editable {
            sensitivity = SensitivityAssessment(
                sensitivity: .normal,
                source: .accessibilityRole,
                capturedAtNanos: nowNanos)
        } else {
            // No evidence: fail closed to unknown (JOE-2258/2259).
            sensitivity = SensitivityAssessment(
                sensitivity: .unknown,
                source: .noEvidence,
                capturedAtNanos: nowNanos)
        }

        let snapshot = TargetSnapshot(
            sessionID: sessionID,
            capturedAtUptimeNanos: nowNanos,
            target: .init(
                pid: pid,
                bundleID: bundle,
                processStartUptimeNanos: processStartNanos(pid: pid),
                windowID: frontmostWindowID(pid: pid, element: element),
                appVersion: bundleShortVersion(bundle)),
            element: .init(
                role: role ?? "unknown",
                subrole: subrole,
                resolutionToken: identifier),
            settable: settable,
            editable: editable,
            enabled: enabled,
            selectionRange: nil,
            sensitivity: sensitivity)
        ZFLog.info("revalidate: snapshot pid=\(pid) role=\(role ?? "nil") sens=\(sensitivity.sensitivity.rawValue)")
        return snapshot
    }

    // MARK: re-resolution (immediately before insertion)

    func currentContext(nowNanos: UInt64) async -> TargetValidationContext? {
        guard isAxTrusted else { return nil }
        guard let app = focusedAXApplication() else { return nil }
        let pid = app.processIdentifier
        guard let bundle = app.bundleIdentifier, !isIgnorable(bundleID: bundle) else { return nil }
        let element = focusedElement(of: app)
        let role = element.flatMap { attr($0, kAXRoleAttribute) }
        let subrole = element.flatMap { attr($0, kAXSubroleAttribute) }
        let identifier = element.flatMap { attr($0, kAXIdentifierAttribute) }
        let isSecure = role == "AXSecureTextField"
        let editable = element.map { textLikeRoles.contains(attr($0, kAXRoleAttribute) ?? "") } ?? false
        let sensitivity: SensitivityAssessment
        if isSecure {
            sensitivity = SensitivityAssessment(
                sensitivity: .secure,
                source: .accessibilityRole,
                capturedAtNanos: nowNanos)
        } else if editable {
            sensitivity = SensitivityAssessment(
                sensitivity: .normal,
                source: .accessibilityRole,
                capturedAtNanos: nowNanos)
        } else {
            sensitivity = SensitivityAssessment(
                sensitivity: .unknown,
                source: .noEvidence,
                capturedAtNanos: nowNanos)
        }
        return TargetValidationContext(
            pid: pid,
            bundleID: bundle,
            processStartUptimeNanos: processStartNanos(pid: pid),
            windowID: frontmostWindowID(pid: pid, element: element),
            element: .init(
                role: role ?? "unknown",
                subrole: subrole,
                resolutionToken: identifier),
            settable: element.map { axSettable($0) } ?? false,
            editable: editable,
            enabled: element.map { axBool($0, kAXEnabledAttribute) } ?? false,
            sensitivity: sensitivity,
            nowNanos: nowNanos)
    }

    /// Current frontmost user-facing pid (nil when Zephyr/ignored).
    func currentFrontmostPID() -> Int32? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundle = app.bundleIdentifier,
            !isIgnorable(bundleID: bundle)
        else { return nil }
        return app.processIdentifier
    }

    /// Bounded, observable restore: activates the captured app and polls the
    /// monitor until restored, rejected (attempt cap) or deadlineExceeded.
    /// Never sleeps blindly — every wait step re-observes frontmost state.
    func restoreToCapturedTarget(
        snapshot: TargetSnapshot,
        deadlineNanosAhead: UInt64 = 2_000_000_000
    ) async -> TargetRestoreMonitor {
        var monitor = TargetRestoreMonitor(deadlineNanosAhead: deadlineNanosAhead, maxAttempts: 40)
        monitor.start(nowNanos: DispatchTime.now().uptimeNanoseconds)

        // Ask the saved app to activate exactly once, then observe.
        if let target = NSRunningApplication(processIdentifier: snapshot.target.pid) {
            for window in NSApp.windows {
                if window.isKeyWindow || window.isMainWindow {
                    window.resignKey()
                    window.orderBack(nil)
                }
            }
            NSApp.deactivate()
            _ = target.activate(options: [])
        }

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let frontmost = currentFrontmostPID() == snapshot.target.pid
            switch monitor.poll(isFrontmost: frontmost, nowNanos: now) {
            case .restored, .rejected, .deadlineExceeded:
                return monitor
            case .polling:
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: AX helpers

    private func focusedAXApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            let bundle = frontmost.bundleIdentifier,
            !isIgnorable(bundleID: bundle)
        {
            return frontmost
        }
        // Fall back to the AX focused application (without stealing focus).
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
                == .success,
            let appElement = focusedApp
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid((appElement as! AXUIElement), &pid) == .success else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
            let bundle = app.bundleIdentifier, !isIgnorable(bundleID: bundle)
        else { return nil }
        return app
    }

    private func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private func attr(_ element: AXUIElement, _ attribute: String) -> String? {
        attrValue(element, attribute) as? String
    }

    /// Round-6 B3: raw AX attribute value (CFTypeRef). kAXPositionAttribute
    /// and kAXSizeAttribute return AXValue, not String — the old code read
    /// them through the String accessor, so window bounds were never captured
    /// and the captured windowID was always nil.
    private func attrValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    private func axSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// Round-5 B4: window identity derived from the FOCUSED ELEMENT's
    /// kAXWindowAttribute (not the first layer-zero window of the process).
    /// Returns nil when the AX window cannot be resolved or its bounds cannot
    /// be matched to a CGWindowID — callers fail closed (nil window id means
    /// paste requires a lease that cannot be re-validated, so it is refused).
    private func frontmostWindowID(pid: Int32, element: AXUIElement?) -> UInt32? {
        guard let element else { return nil }
        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef,
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self)
        // Read the AX window's bounds (position+size) via the CFTypeRef
        // accessor — these attributes return AXValue (round-6 B3).
        var position = CGPoint.zero
        var size = CGSize.zero
        var posOK = false
        var sizeOK = false
        if let posRef = attrValue(windowElement, kAXPositionAttribute as String),
            CFGetTypeID(posRef) == AXValueGetTypeID()
        {
            AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
            posOK = true
        }
        if let sizeRef = attrValue(windowElement, kAXSizeAttribute as String),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        {
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
            sizeOK = true
        }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Match the CG window owned by this PID whose bounds match the AX
        // window's bounds (same origin within tolerance + same size). No
        // bounds match => nil (fail closed; never the first PID window).
        for w in list {
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value == pid,
                let winID = w[kCGWindowNumber as String] as? NSNumber
            else { continue }
            guard posOK, sizeOK,
                let bounds = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let bx = bounds["X"] ?? 0
            let by = bounds["Y"] ?? 0
            let bw = bounds["Width"] ?? 0
            let bh = bounds["Height"] ?? 0
            let matches =
                abs(bx - position.x) < 2 && abs(by - position.y) < 2
                && abs(bw - size.width) < 2 && abs(bh - size.height) < 2
            if matches {
                return UInt32(winID.int32Value)
            }
        }
        return nil
    }

    private func processStartNanos(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard rc > 0 else { return nil }
        let seconds = UInt64(info.pbi_start_tvsec)
        let micros = UInt64(info.pbi_start_tvusec)
        return seconds * 1_000_000_000 + micros * 1_000
    }

    private func bundleShortVersion(_ bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: appURL)
        else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func isIgnorable(bundleID: String) -> Bool {
        if bundleID == ownBundleID { return true }
        return ignoredBundleIDs.contains(bundleID)
    }

    private let ignoredBundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent",
        "com.apple.notificationcenterUI", "com.apple.controlcenter",
        "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.dock",
    ]
}
