import Foundation

// JOE-2287: one serial deduplicated edge stream for global hotkey delivery.
//
// Raw CGEvent-tap / NSEvent-monitor callbacks become compact timestamped
// source events and feed EXACTLY ONE serial edge-state machine. Source
// priority (tap > global > local) plus a deduplication window collapses
// simultaneous observations into ONE logical press/release. Autorepeat,
// modifier chords, side-specific modifiers, lost release, tap-disabled
// events and configuration changes are handled explicitly. Mutable state
// lives only here (value type) — the app layer keeps callbacks
// allocation-/logging-/blocking-minimal.

public enum HotkeySource: String, Codable, Sendable, Equatable {
    case tap  // CGEvent tap (highest priority)
    case global  // NSEvent global monitor
    case local  // NSEvent local monitor (lowest priority)
}

public struct HotkeySourceEvent: Sendable, Equatable {
    public let source: HotkeySource
    public let down: Bool
    public let keyCode: UInt16?
    public let flags: UInt64
    public let isFnKey: Bool
    public let isAutorepeat: Bool
    /// Monotonic timestamp in nanoseconds (caller-provided clock).
    public let timestampNanos: UInt64

    public init(
        source: HotkeySource, down: Bool, keyCode: UInt16?,
        flags: UInt64, isFnKey: Bool, isAutorepeat: Bool = false,
        timestampNanos: UInt64 = 0
    ) {
        self.source = source
        self.down = down
        self.keyCode = keyCode
        self.flags = flags
        self.isFnKey = isFnKey
        self.isAutorepeat = isAutorepeat
        self.timestampNanos = timestampNanos
    }
}

public enum HotkeyLifecycleState: String, Codable, Sendable, Equatable {
    case stopped
    case starting
    case healthy
    case degraded
    case stopping
}

/// Value-only conventional shortcut input. Flags changes can release a chord,
/// but never begin a recording without a fresh non-repeat primary-key down.
public enum StandardHotkeyEvent: Sendable, Equatable {
    case keyDown(keyCode: UInt16, flags: UInt64, isAutorepeat: Bool)
    case keyUp(keyCode: UInt16, flags: UInt64)
    case flagsChanged(flags: UInt64)
}

public struct HotkeyEdgeReport: Sendable, Equatable {
    public let presses: Int
    public let releases: Int
    public let suppressed: Int
    public let lostReleasesRecovered: Int
    public let violations: [String]

    public var isGreen: Bool { violations.isEmpty }
}

/// One serial edge-state machine. Mutating value type: the owning actor
/// owns all mutable hotkey state.
public struct HotkeyEdgeStream: Sendable, Equatable {
    public static let dedupWindowNanos: UInt64 = 30_000_000  // 30 ms
    public static let lostReleaseTimeoutNanos: UInt64 = 2_000_000_000  // 2 s
    public static let autorepeatWindowNanos: UInt64 = 40_000_000

    public private(set) var lifecycle: HotkeyLifecycleState = .stopped
    public private(set) var heldDown = false
    public private(set) var presses = 0
    public private(set) var releases = 0
    public private(set) var suppressed = 0
    public private(set) var lostReleasesRecovered = 0
    public private(set) var violations: [String] = []

    private var lastLogicalDownNanos: UInt64?
    private var lastLogicalUpNanos: UInt64?
    private var lastPressSource: HotkeySource?
    private var configKeyCode: UInt16?
    private var configIsFn: Bool
    private var chordBlockedUntilRelease = false
    private var standardKeyDown = false
    public static let conventionalModifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    public init(configIsFn: Bool, configKeyCode: UInt16? = nil) {
        self.configIsFn = configIsFn
        self.configKeyCode = configKeyCode
    }

    public var isGreen: Bool { violations.isEmpty }
    public var report: HotkeyEdgeReport {
        HotkeyEdgeReport(
            presses: presses, releases: releases,
            suppressed: suppressed,
            lostReleasesRecovered: lostReleasesRecovered,
            violations: violations)
    }

    /// Configuration changes affect FUTURE events and reset held state
    /// safely (a stale held-down edge is released).
    public mutating func applyConfig(isFn: Bool, keyCode: UInt16?) {
        configIsFn = isFn
        configKeyCode = keyCode
        if heldDown {
            emitRelease(reason: "config-change")
        }
        heldDown = false
        lastLogicalDownNanos = nil
        lastPressSource = nil
        chordBlockedUntilRelease = false
        standardKeyDown = false
    }

    public mutating func setLifecycle(_ state: HotkeyLifecycleState) {
        lifecycle = state
        if state == .stopped || state == .stopping {
            // Never leave hold/toggle permanently armed.
            if heldDown {
                emitRelease(reason: "lifecycle-\(state.rawValue)")
            }
            heldDown = false
            standardKeyDown = false
        }
    }

    /// Called under the same owner lock as feed/configuration/lifecycle. The
    /// primary key stays physically latched after modifier release, so adding
    /// modifiers back or autorepeat cannot re-arm a partially released chord.
    public mutating func feedStandard(
        _ event: StandardHotkeyEvent, requiredModifiers: UInt64, timestampNanos: UInt64
    ) -> Bool? {
        guard !configIsFn, let key = configKeyCode, lifecycle == .healthy || lifecycle == .degraded else { return nil }
        let required = requiredModifiers & Self.conventionalModifierMask
        let down: Bool
        let flags: UInt64
        switch event {
        case .keyDown(let eventKey, let current, let autorepeat):
            guard eventKey == key, !autorepeat, !standardKeyDown else { return nil }
            standardKeyDown = true
            guard current & Self.conventionalModifierMask == required else { return nil }
            down = true
            flags = current
        case .keyUp(let eventKey, let current):
            guard eventKey == key else { return nil }
            standardKeyDown = false
            down = false
            flags = current  // Release is independent of the remaining modifiers.
        case .flagsChanged(let current):
            guard standardKeyDown, heldDown, current & Self.conventionalModifierMask != required else { return nil }
            down = false
            flags = current
        }
        return feed(
            HotkeySourceEvent(
                source: .tap, down: down, keyCode: key, flags: flags,
                isFnKey: false, timestampNanos: timestampNanos)) ? down : nil
    }

    /// Feed one raw source event. Returns true when a logical edge is
    /// emitted (the consumer may call the press/release side effect).
    public mutating func feed(_ event: HotkeySourceEvent) -> Bool {
        // Tap-disabled events are surfaced by the caller as degraded; the
        // machine itself treats them as no-ops (never busy-loops).
        switch lifecycle {
        case .stopped, .stopping, .starting:
            return false
        case .healthy, .degraded:
            break
        }

        // Fn configuration: only Fn-key flagsChanged events count.
        if configIsFn {
            guard event.isFnKey || isFnFlag(event) else {
                // Non-Fn events cannot arm hold/toggle state.
                if event.down { suppressed += 1 }
                return false
            }
        } else if let kc = configKeyCode {
            guard event.keyCode == kc else {
                if event.down { suppressed += 1 }
                return false
            }
        }

        // Autorepeat never produces edges.
        if event.isAutorepeat {
            suppressed += 1
            return false
        }

        // CGEventFlags: shift=1<<17, control=1<<18, option=1<<19,
        // command=1<<20. Fn with a chord never arms; it still releases a
        // prior hold so adding a modifier cannot strand capture.
        let chordModifiers = Self.conventionalModifierMask
        let chordPresent = (event.flags & chordModifiers) != 0
        if configIsFn {
            if !event.down { chordBlockedUntilRelease = false }
            if chordPresent || chordBlockedUntilRelease {
                if event.down { chordBlockedUntilRelease = true }
                if heldDown {
                    emitRelease(reason: "modifier-chord")
                    return true
                }
                if event.down { suppressed += 1 }
                return false
            }
        }

        // Dedup window: an edge from a lower-priority source within the
        // window of the same logical edge from a higher-priority source is
        // absorbed.
        if event.down {
            if let last = lastLogicalDownNanos, event.timestampNanos < last {
                suppressed += 1
                return false
            }
            if let last = lastLogicalDownNanos,
                event.source != lastPressSource,
                event.timestampNanos >= last,
                event.timestampNanos - last < Self.dedupWindowNanos,
                sourcePriority(event.source) <= sourcePriority(lastPressSource ?? .tap)
            {
                suppressed += 1
                return false
            }
            if heldDown {
                // Duplicate down while already held: suppress (never double-arm).
                suppressed += 1
                return false
            }
            heldDown = true
            lastLogicalDownNanos = event.timestampNanos
            lastPressSource = event.source
            presses += 1
            return true
        } else {
            if !heldDown {
                // Release with nothing held: recoverable (lost edge) but not
                // a violation; suppress so one physical action stays one pair.
                suppressed += 1
                return false
            }
            emitRelease(reason: "normal")
            return true
        }
    }

    /// Elapsed time alone is not lost-release evidence: a real hold can last
    /// ten minutes. Recover only after an explicit observed key-up. Missing
    /// key-state evidence leaves the product capture deadline in control.
    public mutating func sweepLostRelease(nowNanos: UInt64, observedKeyDown: Bool?) -> Bool {
        guard observedKeyDown == false, heldDown, let last = lastLogicalDownNanos, nowNanos >= last else {
            return false
        }
        if nowNanos - last >= Self.lostReleaseTimeoutNanos {
            standardKeyDown = false
            emitRelease(reason: "lost-release-timeout")
            return true
        }
        return false
    }

    private mutating func emitRelease(reason: String) {
        heldDown = false
        releases += 1
        lastLogicalUpNanos = nil
        if reason == "lost-release-timeout" || reason == "lifecycle-stopped"
            || reason == "lifecycle-stopping" || reason == "config-change"
        {
            lostReleasesRecovered += 1
        }
    }

    private func isFnFlag(_ event: HotkeySourceEvent) -> Bool {
        (event.flags & 0x800000) != 0  // device-independent Fn flag
    }

    private func sourcePriority(_ source: HotkeySource?) -> Int {
        switch source ?? .tap {
        case .tap: return 3
        case .global: return 2
        case .local: return 1
        }
    }
}
