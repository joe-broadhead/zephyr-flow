import AppKit
import ApplicationServices
import Darwin
import ZephyrFlowCore

struct TargetApplicationMetadata: Sendable, Equatable {
    let pid: Int32
    let bundleID: String
    let version: String?
}

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

    private let application: @MainActor () -> TargetApplicationMetadata?
    private let trusted: @MainActor () -> Bool
    private let readMetadata: @Sendable (TargetApplicationMetadata, UInt64) -> TargetValidationContext?
    private let readLane: AxOperationLane
    private let readBudgetNanos: UInt64

    init(
        application: (@MainActor () -> TargetApplicationMetadata?)? = nil,
        trusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        readMetadata: (@Sendable (TargetApplicationMetadata, UInt64) -> TargetValidationContext?)? = nil,
        readLane: AxOperationLane = AxOperationLane(), readBudgetNanos: UInt64 = 1_500_000_000
    ) {
        self.application =
            application ?? {
                guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else {
                    return nil
                }
                let version = app.bundleURL.flatMap {
                    Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                }
                return TargetApplicationMetadata(pid: app.processIdentifier, bundleID: bundle, version: version)
            }
        self.trusted = trusted
        self.readMetadata = readMetadata ?? { Self.nativeContext(application: $0, nowNanos: $1) }
        self.readLane = readLane
        self.readBudgetNanos = readBudgetNanos
    }

    var isAxTrusted: Bool { trusted() }

    // MARK: capture (session start)

    func captureSnapshot(sessionID: SessionID, nowNanos: UInt64) async -> TargetSnapshot? {
        guard let (app, context) = await boundedContext(nowNanos: nowNanos) else { return nil }
        let snapshot = TargetSnapshot(
            sessionID: sessionID,
            capturedAtUptimeNanos: nowNanos,
            target: .init(
                pid: context.pid, bundleID: context.bundleID,
                processStartUptimeNanos: context.processStartUptimeNanos,
                windowID: context.windowID, appVersion: app.version),
            element: context.element,
            settable: context.settable,
            editable: context.editable,
            enabled: context.enabled,
            selectionRange: nil,
            sensitivity: context.sensitivity)
        ZFLog.info("revalidate: snapshot pid=\(context.pid) sens=\(context.sensitivity.sensitivity.rawValue)")
        return snapshot
    }

    // MARK: re-resolution (immediately before insertion)

    func currentContext(nowNanos: UInt64) async -> TargetValidationContext? {
        await boundedContext(nowNanos: nowNanos)?.1
    }

    private func boundedContext(nowNanos: UInt64) async -> (TargetApplicationMetadata, TargetValidationContext)? {
        guard !Task.isCancelled, isAxTrusted, let app = application(), app.pid > 0,
            !isIgnorable(bundleID: app.bundleID)
        else { return nil }
        let read = readMetadata
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await AxBoundedRunner.run(
            deadlineNanosAhead: readBudgetNanos,
            startedAtNanos: start, nowNanos: { DispatchTime.now().uptimeNanoseconds }, lane: readLane,
            operation: { read(app, nowNanos) })
        // No native handles cross this await. Late/failed/busy reads are
        // unknown, and a frontmost-app or trust change invalidates publication.
        guard !Task.isCancelled, isAxTrusted, application() == app,
            let optionalContext = result.value, let context = optionalContext,
            context.pid == app.pid, context.bundleID == app.bundleID
        else { return nil }
        return (app, context)
    }

    private nonisolated static func nativeContext(application app: TargetApplicationMetadata, nowNanos: UInt64)
        -> TargetValidationContext?
    {
        let pid = app.pid
        guard let processStart = ProcessStartIdentity.read(pid: pid) else { return nil }
        let element = focusedElement(pid: pid)
        let evidence = element.map { AXSensitivityReader.read($0) }
        let role = evidence?.role.value
        let subrole = evidence?.subrole.value
        let identifier = element.flatMap { attr($0, kAXIdentifierAttribute) }
        let editable = evidence?.editable ?? false
        let classification = evidence?.sensitivity ?? .unknown
        let sensitivity = SensitivityAssessment(
            sensitivity: classification,
            source: classification == .unknown ? .noEvidence : .accessibilityRole, capturedAtNanos: nowNanos)
        let windowID = frontmostWindowID(pid: pid, element: element)
        guard ProcessStartIdentity.read(pid: pid) == processStart else { return nil }
        return TargetValidationContext(
            pid: pid,
            bundleID: app.bundleID,
            processStartUptimeNanos: processStart,
            windowID: windowID,
            element: .init(
                role: role ?? "unknown",
                subrole: subrole,
                resolutionToken: identifier),
            settable: element.map { axSettable($0) } ?? false,
            editable: editable,
            enabled: evidence?.enabled ?? false,
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

    private nonisolated static func focusedElement(pid: Int32) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(appElement, 0.5) == .success else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let handle = unsafeBitCast(element, to: AXUIElement.self)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(handle, &elementPID) == .success, elementPID == pid,
            AXUIElementSetMessagingTimeout(handle, 0.5) == .success
        else { return nil }
        return handle
    }

    private nonisolated static func attr(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let string = attrValue(element, attribute) as? String, string.utf8.count <= 1024 else { return nil }
        return string
    }

    /// Round-6 B3: raw AX attribute value (CFTypeRef). kAXPositionAttribute
    /// and kAXSizeAttribute return AXValue, not String — the old code read
    /// them through the String accessor, so window bounds were never captured
    /// and the captured windowID was always nil.
    private nonisolated static func attrValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func axSettable(_ element: AXUIElement) -> Bool {
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
    private nonisolated static func frontmostWindowID(pid: Int32, element: AXUIElement?) -> UInt32? {
        guard let element else { return nil }
        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef,
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(windowElement, 0.5) == .success else { return nil }
        // Read the AX window's bounds (position+size) via the CFTypeRef
        // accessor — these attributes return AXValue (round-6 B3).
        var position = CGPoint.zero
        var size = CGSize.zero
        var posOK = false
        var sizeOK = false
        if let posRef = attrValue(windowElement, kAXPositionAttribute as String),
            CFGetTypeID(posRef) == AXValueGetTypeID()
        {
            posOK = AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
        }
        if let sizeRef = attrValue(windowElement, kAXSizeAttribute as String),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        {
            sizeOK = AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
        }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Match the CG window owned by this PID whose bounds match the AX
        // window's bounds (same origin within tolerance + same size). No
        // bounds match => nil (fail closed; never the first PID window).
        var candidate: UInt32?
        for w in list {
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value == pid,
                let winID = w[kCGWindowNumber as String] as? NSNumber,
                let id = UInt32(exactly: winID.int64Value), id > 0
            else { continue }
            guard posOK, sizeOK,
                let bounds = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            guard let bx = bounds["X"], let by = bounds["Y"], let bw = bounds["Width"], let bh = bounds["Height"],
                [bx, by, bw, bh, position.x, position.y, size.width, size.height].allSatisfy(\.isFinite),
                bw > 0, bh > 0, size.width > 0, size.height > 0
            else { continue }
            let matches =
                abs(bx - position.x) < 2 && abs(by - position.y) < 2
                && abs(bw - size.width) < 2 && abs(bh - size.height) < 2
            if matches {
                // Overlapping same-size windows are ambiguous, not identity.
                guard candidate == nil else { return nil }
                candidate = id
            }
        }
        return candidate
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
