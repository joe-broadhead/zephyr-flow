import Foundation

// JOE-2259: one in-process review surface for secure/unknown sessions.
// The display text lives ONLY in this object: it is never logged, never
// persisted, never exposed as accessibility labels or notifications, and is
// cleared deterministically on dismiss, deadline, cancel, termination or an
// explicit user copy.

public final class SecureSessionReview: @unchecked Sendable {
    public enum ClearReason: String, Sendable, Equatable {
        case userDismissed
        case deadlineExpired
        case sessionCancelled
        case appTerminating
        case consumedByExplicitCopy
        case retriedWithFreshIntent  // JOE-2272
    }

    private final class Box {
        var text: String?
        var clearedReason: ClearReason?
        init(text: String?) { self.text = text }
    }

    public let sessionID: SessionID
    /// Continuous-clock capture instant of the review (diagnostics only).
    public let reviewedAtNanos: UInt64
    /// Bounded review window (nanoseconds). At expiry, content is cleared.
    public let deadlineNanosAhead: UInt64
    private let lock = NSLock()
    private let box: Box

    public init(sessionID: SessionID, text: String, nowNanos: UInt64, deadlineNanosAhead: UInt64) {
        self.sessionID = sessionID
        self.reviewedAtNanos = nowNanos
        self.deadlineNanosAhead = deadlineNanosAhead
        self.box = Box(text: text)
    }

    /// In-memory content; nil once cleared.
    public var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return box.text
    }

    public var clearReason: ClearReason? {
        lock.lock()
        defer { lock.unlock() }
        return box.clearedReason
    }

    /// Deadline check with injected clock for deterministic tests.
    public func expired(nowNanos: UInt64) -> Bool {
        nowNanos >= reviewedAtNanos + deadlineNanosAhead
    }

    public func clear(reason: ClearReason) {
        lock.lock()
        defer { lock.unlock() }
        guard box.clearedReason == nil else { return }
        box.text = nil
        box.clearedReason = reason
    }

    /// Explicit user copy: consumes the content, produces a content-free
    /// audit record, and returns the bytes the caller may place on the
    /// clipboard ONLY after this call (never before).
    public func consumeForExplicitCopy(
        decision: SessionSensitivityDecision,
        nowNanos: UInt64
    ) -> (text: String, audit: ExplicitCopyAuditRecord)? {
        lock.lock()
        defer { lock.unlock() }
        guard box.clearedReason == nil, let t = box.text else { return nil }
        box.text = nil
        box.clearedReason = .consumedByExplicitCopy
        return (
            t,
            ExplicitCopyAuditRecord(
                sensitivity: decision.sensitivity,
                upgradedBeforeInsertion: decision.upgradedBeforeInsertion,
                timestampMillis: nowNanos / 1_000_000)
        )
    }
}

/// JOE-2259: one deterministic domain policy enforced by every
/// transcript-bearing service — UI cannot be bypassed through direct service
/// calls because the policy lives here and in SensitivityPolicy.
public enum SensitiveSessionPolicy {
    /// Secure/unknown sessions must not run structural/semantic Flow.
    /// route professional/bullets/summary to the conservative clean style.
    public static func conservativeStyle(for style: FlowStyle) -> FlowStyle {
        switch style {
        case .clean, .raw: return style
        case .professional, .bullets, .summary: return .clean
        }
    }
}

extension SensitiveSessionPolicy {
    public static func automaticInsertAllowed(sensitivity: SessionSensitivity) -> Bool {
        sensitivity.allowsAutomaticSideEffects
    }
    public static func historyWriteAllowed(sensitivity: SessionSensitivity) -> Bool {
        sensitivity.allowsHistory
    }
    public static func clipboardFallbackAllowed(sensitivity: SessionSensitivity) -> Bool {
        sensitivity.allowsClipboardFallback
    }
    public static func autoPasteAllowed(sensitivity: SessionSensitivity) -> Bool {
        sensitivity.allowsAutomaticSideEffects
    }
}
