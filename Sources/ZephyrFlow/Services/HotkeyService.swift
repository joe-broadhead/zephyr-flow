import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ZephyrFlowCore

/// Global hotkey monitor (Wispr-style Fn / Globe).
///
/// Requires **Accessibility**. Ad-hoc rebuilds often drop the TCC grant — we poll
/// and restart the tap when trust appears.
@MainActor
final class HotkeyService: ObservableObject {
    static let shared = HotkeyService()

    enum Event {
        case press
        case release
    }

    @Published private(set) var isKeyDown = false
    @Published private(set) var lastError: String?
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var tapHealthy = false

    private var onEvent: ((Event) -> Void)?
    private var config: HotkeyConfig = .default
    private var mode: ListeningMode = .holdToTalk
    private var toggleArmed = false

    private let engine = HotkeyTapEngine()
    private var axPollTimer: Timer?

    private var originalFnUsageType: Int?
    private var didOverrideFnUsage = false
    private var started = false

    /// Survives crash so next launch can undo a stuck Globe-key override (H1/H2).
    private let fnOverrideMarkerKey = "zephyrflow.fnOverride.active"
    private let fnOverrideOriginalKey = "zephyrflow.fnOverride.original"

    private init() {
        // Crash recovery: previous run may have left AppleFnUsageType=0
        Self.restoreFnOverrideIfNeededFromPriorLaunch()
    }

    /// User-visible recovery if Globe/Fn system preference was left stuck.
    func resetSystemFnPreferenceNow() {
        restoreSystemFnBehavior()
        Self.restoreFnOverrideIfNeededFromPriorLaunch()
        // Also clear HIToolbox key if still present
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        defaults?.removeObject(forKey: "AppleFnUsageType")
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        ZFLog.info("User requested Fn/Globe preference reset")
        // Re-apply override only if Fn is still the configured hotkey and we're running
        if started, config.specialKey == .fn {
            disableSystemFnBehavior()
        }
    }

    /// Call as early as possible (even before HotkeyService.shared if needed).
    static func restoreFnOverrideIfNeededFromPriorLaunch() {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: "zephyrflow.fnOverride.active") else { return }
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        if ud.object(forKey: "zephyrflow.fnOverride.original") != nil {
            let original = ud.integer(forKey: "zephyrflow.fnOverride.original")
            defaults?.set(original, forKey: "AppleFnUsageType")
        } else {
            defaults?.removeObject(forKey: "AppleFnUsageType")
        }
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        ud.set(false, forKey: "zephyrflow.fnOverride.active")
        ud.removeObject(forKey: "zephyrflow.fnOverride.original")
        ZFLog.info("Recovered AppleFnUsageType from prior unclean shutdown")
    }

    func configure(hotkey: HotkeyConfig, mode: ListeningMode) {
        self.config = hotkey
        self.mode = mode
        engine.updateConfig(hotkey)
        ZFLog.info("Hotkey configured: \(hotkey.displayName) mode=\(mode.rawValue)")
    }

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        started = true

        engine.onEdge = { [weak self] down in
            DispatchQueue.main.async { self?.emitEdge(down: down) }
        }
        engine.onStatus = { [weak self] message, healthy in
            DispatchQueue.main.async {
                self?.tapHealthy = healthy
                self?.lastError = healthy ? nil : message
                ZFLog.info("Hotkey engine: \(message)")
            }
        }
        // Debug: log raw Fn-related flag changes so we can see what the keyboard emits
        engine.onDebug = { msg in
            ZFLog.debug("Hotkey \(msg)")
        }

        refreshAccessibility()
        restartEngine()
        startAXPolling()
    }

    func stop() {
        started = false
        axPollTimer?.invalidate()
        axPollTimer = nil
        engine.stop()
        restoreSystemFnBehavior()
        onEvent = nil
        isKeyDown = false
        tapHealthy = false
    }

    func resetToggle() {
        toggleArmed = false
        isKeyDown = false
        engine.resetHeld()
    }

    /// Call after user toggles Accessibility in System Settings.
    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        if changed {
            ZFLog.info("Accessibility trusted=\(trusted)")
        }
        if started, changed {
            restartEngine()
        }
    }

    func requestAccessibilityPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        // Also deep-link settings
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        ZFLog.info("Requested Accessibility prompt + opened Settings")
    }

    private func startAXPolling() {
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibility()
            }
        }
    }

    private func restartEngine() {
        engine.stop()
        restoreSystemFnBehavior()

        guard started else { return }

        if config.specialKey == .fn {
            disableSystemFnBehavior()
        }

        if !AXIsProcessTrusted() {
            lastError = "Enable Accessibility for ZephyrFlow, then wait 1–2s"
            tapHealthy = false
            ZFLog.error("Hotkey waiting for Accessibility (tap not started in default mode)")
            // Still start listenOnly — some systems deliver flagsChanged
            engine.start(preferDefaultTap: false)
            return
        }

        lastError = nil
        engine.start(preferDefaultTap: true)
    }

    // MARK: - System Fn override

    private func disableSystemFnBehavior() {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        if !didOverrideFnUsage {
            originalFnUsageType = defaults?.object(forKey: "AppleFnUsageType") as? Int
            // Persist so crash recovery can restore (H1/H2)
            let ud = UserDefaults.standard
            ud.set(true, forKey: fnOverrideMarkerKey)
            if let original = originalFnUsageType {
                ud.set(original, forKey: fnOverrideOriginalKey)
            } else {
                ud.removeObject(forKey: fnOverrideOriginalKey)
            }
        }
        defaults?.set(0, forKey: "AppleFnUsageType")
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        didOverrideFnUsage = true
        ZFLog.info("Set AppleFnUsageType=0 (was \(originalFnUsageType.map(String.init) ?? "nil"))")
    }

    private func restoreSystemFnBehavior() {
        guard didOverrideFnUsage else { return }
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        if let original = originalFnUsageType {
            defaults?.set(original, forKey: "AppleFnUsageType")
        } else {
            defaults?.removeObject(forKey: "AppleFnUsageType")
        }
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        didOverrideFnUsage = false
        originalFnUsageType = nil
        let ud = UserDefaults.standard
        ud.set(false, forKey: fnOverrideMarkerKey)
        ud.removeObject(forKey: fnOverrideOriginalKey)
        ZFLog.info("Restored AppleFnUsageType")
    }

    // MARK: - Edges

    private func emitEdge(down: Bool) {
        if mode == .holdToTalk {
            if down && !isKeyDown {
                isKeyDown = true
                ZFLog.info("Hotkey PRESS (\(config.displayName))")
                onEvent?(.press)
            } else if !down && isKeyDown {
                isKeyDown = false
                ZFLog.info("Hotkey RELEASE (\(config.displayName))")
                onEvent?(.release)
            }
        } else if down && !isKeyDown {
            isKeyDown = true
            if toggleArmed {
                toggleArmed = false
                ZFLog.info("Hotkey TOGGLE stop")
                onEvent?(.release)
            } else {
                toggleArmed = true
                ZFLog.info("Hotkey TOGGLE start")
                onEvent?(.press)
            }
        } else if !down {
            isKeyDown = false
        }
    }
}

// MARK: - Tap engine

final class HotkeyTapEngine: @unchecked Sendable {
    var onEdge: ((Bool) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onDebug: ((String) -> Void)?

    private let lock = NSLock()
    private var special: HotkeyConfig.SpecialHotkey? = .fn
    private var keyCode: UInt16?
    private var modifiers: UInt = 0

    private var previousFnDown = false
    private var previousModDown = false
    private var standardHeld = false
    private var debugEventCount = 0

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var nsGlobalMonitor: Any?
    private var nsLocalMonitor: Any?

    private let fnKeyCode: Int64 = 0x3F

    func updateConfig(_ config: HotkeyConfig) {
        lock.lock()
        special = config.specialKey
        keyCode = config.keyCode
        modifiers = config.modifiers
        lock.unlock()
    }

    func resetHeld() {
        lock.lock()
        previousFnDown = false
        previousModDown = false
        standardHeld = false
        lock.unlock()
    }

    func start(preferDefaultTap: Bool) {
        stop()

        // NSEvent monitors (main thread) — solid backup when AX is granted
        DispatchQueue.main.async { [weak self] in
            self?.installNSEventMonitors()
        }

        let thread = Thread { [weak self] in
            self?.threadMain(preferDefaultTap: preferDefaultTap)
        }
        thread.name = "ZephyrFlow.HotkeyTap"
        thread.qualityOfService = .userInteractive
        lock.lock()
        tapThread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        // H3: stop runloop first, wait for thread exit, then clear refs under lock.
        lock.lock()
        let runLoop = tapRunLoop
        let thread = tapThread
        lock.unlock()

        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread?.cancel()

        // Brief join — tap thread exits CFRunLoop promptly after stop
        let deadline = Date().addingTimeInterval(0.5)
        while let thread, thread.isExecuting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        lock.lock()
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.removeNSEventMonitors()
        }
        resetHeld()
    }

    // MARK: NSEvent monitors (backup path)

    private func installNSEventMonitors() {
        removeNSEventMonitors()
        nsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        nsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
        onDebug?("NSEvent monitors installed global=\(nsGlobalMonitor != nil)")
    }

    private func removeNSEventMonitors() {
        if let nsGlobalMonitor { NSEvent.removeMonitor(nsGlobalMonitor) }
        if let nsLocalMonitor { NSEvent.removeMonitor(nsLocalMonitor) }
        nsGlobalMonitor = nil
        nsLocalMonitor = nil
    }

    private func handleNSEvent(_ event: NSEvent) {
        lock.lock()
        let special = self.special
        lock.unlock()

        guard special == .fn else {
            // For right modifiers, use keyCode
            if special == .rightOption || special == .rightCommand || special == .rightControl {
                handleNSRightModifier(event, special: special!)
            }
            return
        }

        let fnDown = event.modifierFlags.contains(.function)
            || event.modifierFlags.contains(NSEvent.ModifierFlags(rawValue: UInt(CGEventFlags.maskSecondaryFn.rawValue)))
            || (event.modifierFlags.rawValue & UInt(CGEventFlags.maskSecondaryFn.rawValue)) != 0
            || event.keyCode == 63

        // Also check device-independent function flag
        let altFn = (event.modifierFlags.rawValue & 0x800000) != 0

        let down = fnDown || altFn

        lock.lock()
        let was = previousFnDown
        // Only update if this looks like an Fn-related event
        let keyIsFn = event.keyCode == 63
        let flagsSuggestFn = down || was
        if keyIsFn || flagsSuggestFn {
            if down != was {
                previousFnDown = down
                lock.unlock()
                onDebug?("NSEvent Fn edge down=\(down) keyCode=\(event.keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16))")
                onEdge?(down)
                return
            }
        }
        lock.unlock()
    }

    private func handleNSRightModifier(_ event: NSEvent, special: HotkeyConfig.SpecialHotkey) {
        let expected: UInt16
        let flag: NSEvent.ModifierFlags
        switch special {
        case .rightOption: expected = 61; flag = .option
        case .rightCommand: expected = 54; flag = .command
        case .rightControl: expected = 62; flag = .control
        default: return
        }
        guard event.keyCode == expected else {
            lock.lock()
            let was = previousModDown
            let still = event.modifierFlags.contains(flag)
            if was && !still {
                previousModDown = false
                lock.unlock()
                onEdge?(false)
                return
            }
            lock.unlock()
            return
        }
        let down = event.modifierFlags.contains(flag)
        lock.lock()
        let was = previousModDown
        previousModDown = down
        lock.unlock()
        if down != was {
            onDebug?("NSEvent right-mod edge down=\(down) key=\(expected)")
            onEdge?(down)
        }
    }

    // MARK: CGEvent tap thread

    private func threadMain(preferDefaultTap: Bool) {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<HotkeyTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handleCG(type: type, event: event)
        }

        // Try HID tap first (closer to hardware), then session tap
        let attempts: [(CGEventTapLocation, CGEventTapOptions, String)] = {
            if preferDefaultTap {
                return [
                    (.cghidEventTap, .defaultTap, "hid/default"),
                    (.cgSessionEventTap, .defaultTap, "session/default"),
                    (.cgSessionEventTap, .listenOnly, "session/listen"),
                ]
            }
            return [
                (.cgSessionEventTap, .listenOnly, "session/listen"),
                (.cghidEventTap, .listenOnly, "hid/listen"),
            ]
        }()

        var created: (CFMachPort, String)?
        for (location, options, label) in attempts {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            ) {
                created = (tap, label)
                break
            }
        }

        guard let (tap, label) = created else {
            onStatus?("No event tap — enable Accessibility for ZephyrFlow", false)
            return
        }

        lock.lock()
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let runLoop = CFRunLoopGetCurrent()
        tapRunLoop = runLoop
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        onStatus?("Tap OK (\(label)) ax=\(AXIsProcessTrusted())", true)

        while !Thread.current.isCancelled {
            let result = CFRunLoopRunInMode(.defaultMode, 15.0, false)
            lock.lock()
            let tapRef = eventTap
            lock.unlock()
            if let tapRef, !CGEvent.tapIsEnabled(tap: tapRef) {
                CGEvent.tapEnable(tap: tapRef, enable: true)
                onDebug?("Re-enabled disabled tap")
            }
            if result == .stopped || result == .finished { break }
        }

        lock.lock()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        // Clear lifecycle refs if stop() has not already nulled them
        if eventTap != nil {
            eventTap = nil
            runLoopSource = nil
            tapRunLoop = nil
        }
        lock.unlock()
    }

    private func handleCG(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let special = self.special
        let configuredKey = self.keyCode
        let configuredMods = self.modifiers
        lock.unlock()

        // Debug: sample flagsChanged
        if type == .flagsChanged {
            debugEventCount += 1
            if debugEventCount <= 8 || debugEventCount % 40 == 0 {
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                let fr = event.flags.rawValue
                let secFn = event.flags.contains(.maskSecondaryFn)
                onDebug?("flagsChanged #\(debugEventCount) key=0x\(String(kc, radix: 16)) flags=0x\(String(fr, radix: 16)) secFn=\(secFn)")
            }
        }

        switch special {
        case .fn:
            return handleFnCG(type: type, event: event)
        case .rightOption:
            return handleRightModCG(type: type, event: event, expected: 61, mask: .maskAlternate)
        case .rightCommand:
            return handleRightModCG(type: type, event: event, expected: 54, mask: .maskCommand)
        case .rightControl:
            return handleRightModCG(type: type, event: event, expected: 62, mask: .maskControl)
        case .none:
            return handleStandardCG(type: type, event: event, keyCode: configuredKey, modifiers: configuredMods)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFnCG(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let fnIsDown = flags.contains(.maskSecondaryFn)
            || (flags.rawValue & 0x800000) != 0

        lock.lock()
        let wasDown = previousFnDown
        lock.unlock()

        let fnChanged = fnIsDown != wasDown
        let isFnKey = keyCode == fnKeyCode

        if !fnChanged && !isFnKey {
            return Unmanaged.passUnretained(event)
        }

        // Don't trigger on Fn+Cmd chords etc.
        let other: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        if fnIsDown && !flags.intersection(other).isEmpty {
            lock.lock(); previousFnDown = fnIsDown; lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        if fnChanged || isFnKey {
            let down = fnIsDown
            lock.lock(); previousFnDown = down; lock.unlock()
            onDebug?("CG Fn edge down=\(down) key=0x\(String(keyCode, radix: 16)) flags=0x\(String(flags.rawValue, radix: 16))")
            onEdge?(down)
            // Consume when defaultTap; listenOnly ignores nil vs pass.
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleRightModCG(
        type: CGEventType,
        event: CGEvent,
        expected: Int64,
        mask: CGEventFlags
    ) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flagDown = event.flags.contains(mask)

        if keyCode == expected {
            lock.lock()
            let was = previousModDown
            previousModDown = flagDown
            lock.unlock()
            if flagDown != was { onEdge?(flagDown) }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let was = previousModDown
        lock.unlock()
        if was && !flagDown {
            lock.lock(); previousModDown = false; lock.unlock()
            onEdge?(false)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleStandardCG(
        type: CGEventType,
        event: CGEvent,
        keyCode: UInt16?,
        modifiers: UInt
    ) -> Unmanaged<CGEvent>? {
        guard let keyCode else { return Unmanaged.passUnretained(event) }
        let eventKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKey == keyCode else { return Unmanaged.passUnretained(event) }

        let needed = CGEventFlags(rawValue: UInt64(modifiers))
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let current = event.flags.intersection(relevant)
        let required = needed.intersection(relevant)

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)
            }
            guard current == required else { return Unmanaged.passUnretained(event) }
            lock.lock()
            let already = standardHeld
            standardHeld = true
            lock.unlock()
            if !already { onEdge?(true) }
        } else if type == .keyUp {
            lock.lock()
            let was = standardHeld
            standardHeld = false
            lock.unlock()
            if was { onEdge?(false) }
        }
        return Unmanaged.passUnretained(event)
    }
}
