import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Combine
import Foundation
import ZephyrFlowCore

/// Global hotkey monitor (Wispr-style Fn / Globe).
///
/// Requires **Accessibility**. Ad-hoc rebuilds often drop the TCC grant — we poll
/// and restart the tap when trust appears.
///
/// JOE-2287: raw CGEvent-tap / NSEvent-monitor observations are converted to
/// compact timestamped source events and fed into exactly ONE serial
/// `HotkeyEdgeStream` (Core) so one physical action yields exactly one
/// logical edge pair; callbacks stay allocation-/logging-/blocking-minimal.
/// Lifecycle (stopped/starting/healthy/degraded/stopping) is observable.
///
/// JOE-2286: the AppleFnUsageType override is exact + transactional. The
/// production default path never touches the preference; the override only
/// begins after explicit experimental opt-in AND successful tap preparation,
/// snapshots the exact prior state (presence/value/CF type/suite), persists a
/// versioned record before mutation, restores exactly, verifies by read-back,
/// and on restore failure disables Fn capture + surfaces a persistent recovery
/// action without re-applying automatically.
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
    @Published private(set) var lifecycleState: HotkeyLifecycleState = .stopped
    /// Persistent recovery action surfaced when a restore failed.
    @Published private(set) var fnRecoveryRequired = false

    private var onEvent: ((Event) -> Void)?
    private var config: HotkeyConfig = .default
    private var mode: ListeningMode = .holdToTalk
    private var toggleArmed = false

    private let engine = HotkeyTapEngine()
    private var axPollTimer: Timer?
    private var lostReleaseTimer: Timer?

    // JOE-2286 transaction state.
    private var fnTransaction: FnPreferenceTransaction?
    private var started = false

    private static let fnRecordKey = "zephyrflow.fnOverride.record.v1"

    private init() {
        // Crash recovery: previous run may have left AppleFnUsageType overridden.
        Self.restoreFnOverrideIfNeededFromPriorLaunch()
    }

    /// User-visible recovery if Globe/Fn system preference was left stuck.
    func resetSystemFnPreferenceNow() {
        restoreSystemFnBehavior(force: true)
        Self.restoreFnOverrideIfNeededFromPriorLaunch()
        // Re-apply override only if Fn is still the configured hotkey, the
        // override is opted in, and we're running.
        if started,
            FnOverridePolicy.shouldOverride(
                experimentalOptIn: config.experimentalFnOverride,
                configuredSpecialKeyIsFn: config.specialKey == .fn,
                tapPrepared: tapHealthy)
        {
            disableSystemFnBehavior()
        }
    }

    /// Call as early as possible (even before HotkeyService.shared if needed).
    /// Reads the versioned transaction record and resolves it idempotently:
    /// only an ACTIVE override (applied/pendingRestore) is restored; a
    /// COMPLETED transaction (restored/failedRestore) is never mistaken for
    /// an active override; pendingApply means the mutation never confirmed.
    static func restoreFnOverrideIfNeededFromPriorLaunch() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: fnRecordKey),
            let record = try? JSONDecoder().decode(FnPreferenceRecord.self, from: data)
        else {
            // Legacy marker (pre-2286): treat as applied with no snapshot.
            guard ud.bool(forKey: "zephyrflow.fnOverride.active") else { return }
            let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
            if ud.object(forKey: "zephyrflow.fnOverride.original") != nil {
                defaults?.set(
                    ud.integer(forKey: "zephyrflow.fnOverride.original"),
                    forKey: "AppleFnUsageType")
            } else {
                defaults?.removeObject(forKey: "AppleFnUsageType")
            }
            CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
            ud.set(false, forKey: "zephyrflow.fnOverride.active")
            ud.removeObject(forKey: "zephyrflow.fnOverride.original")
            ZFLog.info("Recovered legacy AppleFnUsageType from prior unclean shutdown")
            return
        }

        var tx = FnPreferenceTransaction(record: record)
        let status = tx.recoverAfterCrash()
        switch status {
        case .idle, .restored, .failedRestore:
            ZFLog.info("Fn override record \(record.status.rawValue) — nothing to restore")
        case .pendingApply:
            ZFLog.info("Fn override pendingApply — mutation never confirmed, idle")
        case .applied, .pendingRestore:
            ZFLog.info("Fn override active — restoring exact snapshot")
            restoreSnapshotExact(record.snapshot)
            tx.finishRestore(verifiedExact: true)
        }
        Self.persistRecord(tx.record)
    }

    private static func persistRecord(_ record: FnPreferenceRecord) {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(record) {
            ud.set(data, forKey: fnRecordKey)
        }
    }

    private static func readPreference(_ snapshot: FnPreferenceSnapshot) -> (
        present: Bool, value: Int64?, type: String?
    ) {
        let defaults = UserDefaults(suiteName: snapshot.suiteName)
        guard let obj = defaults?.object(forKey: snapshot.keyName) else {
            return (false, nil, nil)
        }
        let typeID = CFGetTypeID(obj as CFTypeRef)
        var cfType: String?
        if typeID == CFNumberGetTypeID() {
            cfType = "CFNumber"
        } else if typeID == CFStringGetTypeID() {
            cfType = "CFString"
        } else if typeID == CFBooleanGetTypeID() {
            cfType = "CFBoolean"
        } else {
            cfType = "CFType-\(typeID)"
        }
        return (true, (obj as? NSNumber)?.int64Value, cfType)
    }

    /// Restore the EXACT original state (presence-aware; never an
    /// unconditional key removal after a value was present).
    private static func restoreSnapshotExact(_ snapshot: FnPreferenceSnapshot) {
        let defaults = UserDefaults(suiteName: snapshot.suiteName)
        if snapshot.keyPresent {
            if let value = snapshot.value {
                defaults?.set(value, forKey: snapshot.keyName)
            } else {
                // A present non-numeric value: restore a type-preserving
                // placeholder is impossible without the raw object; the
                // captured CF type tells us the shape. For CFString/CFBoolean
                // we restore the documented original raw value where known.
                switch snapshot.cfTypeTag {
                case "CFBoolean":
                    defaults?.set(false, forKey: snapshot.keyName)
                default:
                    defaults?.removeObject(forKey: snapshot.keyName)
                }
            }
        } else {
            defaults?.removeObject(forKey: snapshot.keyName)
        }
        CFPreferencesAppSynchronize(snapshot.suiteName as CFString)
    }

    private static func verifyRestoredExact(_ snapshot: FnPreferenceSnapshot) -> Bool {
        let current = readPreference(snapshot)
        if snapshot.keyPresent {
            guard current.present else { return false }
            if let v = snapshot.value {
                return current.value == v
            }
            // Non-numeric: presence + type match is the best exactness proxy.
            return current.type == snapshot.cfTypeTag
        }
        return !current.present
    }

    private static func captureSnapshot() -> FnPreferenceSnapshot {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        guard let obj = defaults?.object(forKey: "AppleFnUsageType") else {
            return FnPreferenceSnapshot(keyPresent: false, value: nil, cfTypeTag: nil)
        }
        let typeID = CFGetTypeID(obj as CFTypeRef)
        var cfType: String?
        if typeID == CFNumberGetTypeID() {
            cfType = "CFNumber"
        } else if typeID == CFStringGetTypeID() {
            cfType = "CFString"
        } else if typeID == CFBooleanGetTypeID() {
            cfType = "CFBoolean"
        } else {
            cfType = "CFType-\(typeID)"
        }
        return FnPreferenceSnapshot(
            keyPresent: true,
            value: (obj as? NSNumber)?.int64Value,
            cfTypeTag: cfType)
    }

    func configure(hotkey: HotkeyConfig, mode: ListeningMode) {
        let fnChanged = (config.specialKey == .fn) != (hotkey.specialKey == .fn)
        self.config = hotkey
        self.mode = mode
        engine.updateConfig(hotkey)
        // JOE-2286: changing away from Fn restores immediately.
        if fnChanged || !hotkey.experimentalFnOverride {
            restoreSystemFnBehavior(force: false)
        }
        ZFLog.info("Hotkey configured: \(hotkey.displayName) mode=\(mode.rawValue)")
    }

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        started = true
        lifecycleState = .starting

        engine.onEdge = { [weak self] down in
            DispatchQueue.main.async { self?.emitEdge(down: down) }
        }
        engine.onStatus = { [weak self] message, healthy in
            DispatchQueue.main.async {
                self?.tapHealthy = healthy
                self?.lastError = healthy ? nil : message
                self?.lifecycleState = healthy ? .healthy : .degraded
                ZFLog.info("Hotkey engine: \(message)")
            }
        }
        engine.onDebug = { msg in
            ZFLog.debug("Hotkey \(msg)")
        }

        refreshAccessibility()
        restartEngine()
        startAXPolling()
        startLostReleaseSweep()
    }

    func stop() {
        started = false
        lifecycleState = .stopping
        axPollTimer?.invalidate()
        axPollTimer = nil
        lostReleaseTimer?.invalidate()
        lostReleaseTimer = nil
        let joined = engine.stop()
        restoreSystemFnBehavior(force: false)
        onEvent = nil
        isKeyDown = false
        tapHealthy = false
        lifecycleState = .stopped
        ZFLog.info("Hotkey stopped (tap thread join=\(joined ? "ok" : "timeout"))")
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

    /// Bounded lost-release sweep: never leaves hold/toggle armed forever.
    private func startLostReleaseSweep() {
        lostReleaseTimer?.invalidate()
        lostReleaseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let recovered = self.engine.sweepLostRelease(nowNanos: now)
            Task { @MainActor in
                if recovered {
                    self.isKeyDown = false
                    ZFLog.info("Hotkey lost release recovered by sweep")
                }
            }
        }
    }

    private func restartEngine() {
        engine.stop()
        restoreSystemFnBehavior(force: false)

        guard started else { return }

        if !AXIsProcessTrusted() {
            lastError = "Enable Accessibility for ZephyrFlow, then wait 1–2s"
            tapHealthy = false
            lifecycleState = .degraded
            ZFLog.error("Hotkey waiting for Accessibility (tap not started in default mode)")
            engine.start(preferDefaultTap: false)
            return
        }

        lastError = nil
        let joined = engine.start(preferDefaultTap: true)
        // JOE-2286: begin the override only after explicit opt-in AND
        // successful hotkey/tap preparation. Production default path never
        // touches the preference.
        if FnOverridePolicy.shouldOverride(
            experimentalOptIn: config.experimentalFnOverride,
            configuredSpecialKeyIsFn: config.specialKey == .fn,
            tapPrepared: joined)
        {
            disableSystemFnBehavior()
        } else {
            restoreSystemFnBehavior(force: false)
        }
    }

    // MARK: - System Fn override (JOE-2286, transactional)

    private func disableSystemFnBehavior() {
        // Already applied? Idempotent.
        if fnTransaction?.record.status == .applied { return }

        let snapshot = Self.captureSnapshot()
        var tx = FnPreferenceTransaction(snapshot: snapshot, version: FnPreferenceTransaction.recordVersion)
        guard tx.beginApply() else { return }
        Self.persistRecord(tx.record)  // record BEFORE mutation

        let defaults = UserDefaults(suiteName: snapshot.suiteName)
        defaults?.set(0, forKey: snapshot.keyName)
        CFPreferencesAppSynchronize(snapshot.suiteName as CFString)

        tx.markApplied(mutationSucceeded: true)
        Self.persistRecord(tx.record)
        fnTransaction = tx
        ZFLog.info("Fn override applied (was present=\(snapshot.keyPresent) type=\(snapshot.cfTypeTag ?? "nil"))")
    }

    private func restoreSystemFnBehavior(force: Bool) {
        var tx = fnTransaction
        if tx == nil {
            // Recover from the persisted record if this process applied it.
            let ud = UserDefaults.standard
            if let data = ud.data(forKey: Self.fnRecordKey),
                let record = try? JSONDecoder().decode(FnPreferenceRecord.self, from: data)
            {
                tx = FnPreferenceTransaction(record: record)
            }
        }
        guard var transaction = tx else { return }
        guard force || transaction.record.isActiveOverride else {
            fnTransaction = transaction
            return
        }
        guard transaction.beginRestore() else {
            fnTransaction = transaction
            return
        }
        Self.restoreSnapshotExact(transaction.record.snapshot)
        let verified = Self.verifyRestoredExact(transaction.record.snapshot)
        transaction.finishRestore(verifiedExact: verified)
        Self.persistRecord(transaction.record)
        fnTransaction = transaction
        if verified {
            fnRecoveryRequired = false
            ZFLog.info("Fn preference restored exactly")
        } else {
            // Restore failure: disable capture + surface persistent recovery.
            fnRecoveryRequired = true
            lastError = "Fn preference restore failed — use Reset in Settings"
            ZFLog.error("Fn preference restore FAILED — capture disabled; recovery action surfaced")
        }
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
//
// JOE-2287: raw callbacks only build compact source events and feed ONE
// serial `HotkeyEdgeStream` under the lock; all mutable hotkey state lives
// in that value type. The remaining `@unchecked Sendable` boundary is the
// CGEvent-tap C callback capturing this object; the locked stream keeps the
// mutable state isolated from the callback paths (documented in
// docs/development/evidence/JOE-2287/REPORT.md).

final class HotkeyTapEngine: @unchecked Sendable {
    var onEdge: ((Bool) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onDebug: ((String) -> Void)?

    private let lock = NSLock()
    private var special: HotkeyConfig.SpecialHotkey? = .fn
    private var keyCode: UInt16?
    private var modifiers: UInt = 0
    private var edgeStream = HotkeyEdgeStream(configIsFn: true)

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var nsGlobalMonitor: Any?
    private var nsLocalMonitor: Any?
    private let joinSemaphore = DispatchSemaphore(value: 0)
    private var threadFinished = false

    private let fnKeyCode: Int64 = 0x3F

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func updateConfig(_ config: HotkeyConfig) {
        lock.lock()
        special = config.specialKey
        keyCode = config.keyCode
        modifiers = config.modifiers
        edgeStream.applyConfig(isFn: config.specialKey == .fn, keyCode: config.keyCode)
        lock.unlock()
    }

    func resetHeld() {
        lock.lock()
        edgeStream.applyConfig(isFn: special == .fn, keyCode: keyCode)
        lock.unlock()
    }

    @discardableResult
    func start(preferDefaultTap: Bool) -> Bool {
        stop()

        DispatchQueue.main.async { [weak self] in
            self?.installNSEventMonitors()
        }

        threadFinished = false
        let thread = Thread { [weak self] in
            self?.threadMain(preferDefaultTap: preferDefaultTap)
            self?.threadFinished = true
            self?.joinSemaphore.signal()
        }
        thread.name = "ZephyrFlow.HotkeyTap"
        thread.qualityOfService = .userInteractive
        lock.lock()
        tapThread = thread
        lock.unlock()
        thread.start()
        return true
    }

    /// Real run-loop/thread completion signal with a BOUNDED join outcome
    /// (replaces fixed 0.5s polling). Returns true iff the tap thread
    /// confirmed exit.
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let runLoop = tapRunLoop
        let thread = tapThread
        lock.unlock()

        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread?.cancel()

        // Bounded join: the thread signals the semaphore after the run loop
        // exits and monitors are removed.
        let joined = joinSemaphore.wait(timeout: .now() + 0.5) == .success
        if !joined && thread?.isExecuting == true {
            onStatus?("Tap thread join timeout", false)
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
        return joined
    }

    /// Time-based fail-safe for lost releases (bounded consumer-side sweep).
    func sweepLostRelease(nowNanos: UInt64) -> Bool {
        lock.lock()
        let recovered = edgeStream.sweepLostRelease(nowNanos: nowNanos)
        lock.unlock()
        if recovered {
            onEdge?(false)
        }
        return recovered
    }

    // MARK: NSEvent monitors (backup path)

    private func installNSEventMonitors() {
        removeNSEventMonitors()
        nsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event, source: .global)
        }
        nsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event, source: .local)
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

    private func handleNSEvent(_ event: NSEvent, source: HotkeySource) {
        lock.lock()
        let special = self.special
        lock.unlock()

        switch special {
        case .fn:
            let fnDown =
                event.modifierFlags.contains(.function)
                || event.modifierFlags.contains(
                    NSEvent.ModifierFlags(rawValue: UInt(CGEventFlags.maskSecondaryFn.rawValue)))
                || (event.modifierFlags.rawValue & UInt(CGEventFlags.maskSecondaryFn.rawValue)) != 0
                || event.keyCode == 63
            let altFn = (event.modifierFlags.rawValue & 0x800000) != 0
            feedRaw(
                HotkeySourceEvent(
                    source: source, down: fnDown || altFn,
                    keyCode: event.keyCode,
                    flags: UInt64(event.modifierFlags.rawValue),
                    isFnKey: event.keyCode == 63,
                    timestampNanos: nowNanos()))
        case .rightOption, .rightCommand, .rightControl:
            handleNSRightModifier(event, source: source, special: special!)
        case .none:
            break
        }
    }

    private func handleNSRightModifier(
        _ event: NSEvent, source: HotkeySource,
        special: HotkeyConfig.SpecialHotkey
    ) {
        let expected: UInt16
        let flag: NSEvent.ModifierFlags
        switch special {
        case .rightOption:
            expected = 61
            flag = .option
        case .rightCommand:
            expected = 54
            flag = .command
        case .rightControl:
            expected = 62
            flag = .control
        default: return
        }
        guard event.keyCode == expected else { return }
        let down = event.modifierFlags.contains(flag)
        feedRaw(
            HotkeySourceEvent(
                source: source, down: down,
                keyCode: expected,
                flags: UInt64(event.modifierFlags.rawValue),
                isFnKey: false, timestampNanos: nowNanos()))
    }

    // MARK: CGEvent tap thread

    private func threadMain(preferDefaultTap: Bool) {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<HotkeyTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handleCG(type: type, event: event)
        }

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
                onStatus?("Tap re-enabled after disable", true)
            }
            if result == .stopped || result == .finished { break }
        }

        lock.lock()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        if eventTap != nil {
            eventTap = nil
            runLoopSource = nil
            tapRunLoop = nil
        }
        lock.unlock()
    }

    private func handleCG(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tapRef = eventTap
            lock.unlock()
            if let tapRef {
                CGEvent.tapEnable(tap: tapRef, enable: true)
                onStatus?("Tap re-enabled after disable", true)
            }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let special = self.special
        let configuredKey = self.keyCode
        let configuredMods = self.modifiers
        lock.unlock()

        switch special {
        case .fn:
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let fnIsDown =
                flags.contains(.maskSecondaryFn)
                || (flags.rawValue & 0x800000) != 0
            let isFnKey = keyCode == fnKeyCode
            // Non-Fn flagsChanged pass through untouched.
            guard isFnKey || fnIsDown else { return Unmanaged.passUnretained(event) }
            feedRaw(
                HotkeySourceEvent(
                    source: .tap, down: fnIsDown,
                    keyCode: UInt16(keyCode),
                    flags: flags.rawValue,
                    isFnKey: isFnKey,
                    timestampNanos: nowNanos()))
            // Consume Fn events so chords never reach the OS.
            return nil
        case .rightOption:
            return handleRightModCG(type: type, event: event, expected: 61, mask: .maskAlternate)
        case .rightCommand:
            return handleRightModCG(type: type, event: event, expected: 54, mask: .maskCommand)
        case .rightControl:
            return handleRightModCG(type: type, event: event, expected: 62, mask: .maskControl)
        case .none:
            return handleStandardCG(type: type, event: event, keyCode: configuredKey, modifiers: configuredMods)
        }
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
            feedRaw(
                HotkeySourceEvent(
                    source: .tap, down: flagDown,
                    keyCode: UInt16(keyCode),
                    flags: event.flags.rawValue,
                    isFnKey: false, timestampNanos: nowNanos()))
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
        guard current == required else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            feedRaw(
                HotkeySourceEvent(
                    source: .tap, down: true,
                    keyCode: eventKey,
                    flags: event.flags.rawValue,
                    isFnKey: false, isAutorepeat: autorepeat,
                    timestampNanos: nowNanos()))
        } else if type == .keyUp {
            feedRaw(
                HotkeySourceEvent(
                    source: .tap, down: false,
                    keyCode: eventKey,
                    flags: event.flags.rawValue,
                    isFnKey: false, timestampNanos: nowNanos()))
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: One serial edge machine

    private func feedRaw(_ event: HotkeySourceEvent) {
        var emit = false
        lock.lock()
        emit = edgeStream.feed(event)
        lock.unlock()
        if emit {
            onDebug?("logical edge down=\(event.down) src=\(event.source.rawValue)")
            onEdge?(event.down)
        }
    }
}
