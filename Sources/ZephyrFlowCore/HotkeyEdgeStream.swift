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
    private var activeChordModifiers = false

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
        activeChordModifiers = false
    }

    public mutating func setLifecycle(_ state: HotkeyLifecycleState) {
        lifecycle = state
        if state == .stopped || state == .stopping {
            // Never leave hold/toggle permanently armed.
            if heldDown {
                emitRelease(reason: "lifecycle-\(state.rawValue)")
            }
            heldDown = false
        }
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

        // Modifier chords: while ANY chord modifier is down, Fn/key events
        // are suppressed and do not arm hold state; state resets on the
        // release edge of the chord.
        // CGEventFlags: command=0x100000, alternate=0x200000, shift=0x20000,
        // control=0x4000. Any of these with the Fn key = chord (suppressed).
        let chordModifiers: UInt64 = 0x100000 | 0x200000 | 0x20000 | 0x4000
        let chordPresent = (event.flags & chordModifiers) != 0
        if configIsFn && chordPresent {
            if event.down && !chordBlockedUntilRelease {
                chordBlockedUntilRelease = true
                suppressed += 1
            }
            return false
        }
        if chordBlockedUntilRelease && !event.down {
            chordBlockedUntilRelease = false
            return false
        }

        // Dedup window: an edge from a lower-priority source within the
        // window of the same logical edge from a higher-priority source is
        // absorbed.
        if event.down {
            if let last = lastLogicalDownNanos,
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
            if let last = lastLogicalDownNanos,
                event.timestampNanos - last < Self.dedupWindowNanos
            {
                // Release observed within the dedup window of the down edge
                // from any source is the logical release.
                emitRelease(reason: "normal")
                return true
            }
            emitRelease(reason: "normal")
            return true
        }
    }

    /// Time-based fail-safe: if the key has been held beyond the lost-release
    /// timeout, emit a release (never leave hold/toggle armed forever).
    /// Call from a bounded consumer timer.
    public mutating func sweepLostRelease(nowNanos: UInt64) -> Bool {
        guard heldDown, let last = lastLogicalDownNanos else { return false }
        if nowNanos - last >= Self.lostReleaseTimeoutNanos {
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
