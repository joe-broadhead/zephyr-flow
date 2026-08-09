import Foundation

// JOE-2272: no-side-effect review UX model for uncertain insertion outcomes.
//
// Deterministic, AppKit-free: the controller/panel consume this model to show
// the controlled reason and the exact set of safe actions for every
// `InsertionOutcome` uncertainty case. Text never lives here — the panel owns
// in-process content under SecureSessionReview (JOE-2259); this model is
// content-free (reason + actions + retention).

/// Safe user actions available on an uncertain-outcome review panel.
public enum InsertionReviewAction: String, Codable, CaseIterable, Sendable, Equatable {
    /// Return focus and re-run validation against a FRESH captured target.
    case retryValidation
    /// Explicit user copy (always warned for secure/unknown).
    case explicitCopy
    /// Discard the in-memory text.
    case discard
    /// Open the relevant permission/settings page.
    case openAccessibilitySettings
}

/// Content-free review model for one uncertain outcome (JOE-2272).
public struct InsertionReviewModel: Sendable, Equatable {
    public enum ClearReason: String, Codable, Sendable, Equatable {
        case userDiscarded
        case userCopied
        case retriedWithFreshIntent
        case expired
        case sessionCancelled
        case appTerminating
    }

    public let outcome: InsertionOutcome
    /// Retention deadline (bounded; content expires and is cleared after).
    public let retentionNanosAhead: UInt64
    public let createdAtNanos: UInt64
    public private(set) var clearReason: ClearReason?
    public private(set) var consumedAction: InsertionReviewAction?

    public init(
        outcome: InsertionOutcome,
        createdAtNanos: UInt64,
        retentionNanosAhead: UInt64 = 30_000_000_000
    ) {
        self.outcome = outcome
        self.createdAtNanos = createdAtNanos
        self.retentionNanosAhead = retentionNanosAhead
        self.clearReason = nil
        self.consumedAction = nil
    }

    /// User-understandable headline (never technical AX terminology).
    public var title: String {
        switch outcome {
        case .targetChanged: return "The target changed"
        case .targetGone: return "The target closed"
        case .targetUnknown: return "Target could not be confirmed"
        case .secureTarget: return "Secure field detected"
        case .notEditable: return "Field is not editable"
        case .deadlineExceeded: return "Timed out waiting for the target"
        case .automaticCopy:
            return "Copied to clipboard automatically"
        case .automaticCopyBlocked:
            return "Automatic clipboard blocked"
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
            .cancelled, .failed:
            return "Nothing was inserted"
        }
    }

    /// Plain-language explanation (content-free, no AX jargon).
    public var detail: String {
        switch outcome {
        case .targetChanged:
            return "The app or window you were typing into changed while you spoke. Nothing was inserted."
        case .targetGone:
            return "The app you were typing into closed while you spoke. Nothing was inserted."
        case .targetUnknown:
            return "Zephyr could not confirm where to type. Allow Accessibility in System Settings, then try again."
        case .secureTarget:
            return "A secure field was detected. Nothing was pasted or saved. You can copy explicitly if you choose."
        case .notEditable:
            return "The field you were typing into is read-only. Nothing was inserted."
        case .deadlineExceeded:
            return "The target did not respond in time. Nothing was inserted."
        case .automaticCopy:
            return "The clipboard was written automatically (copy-only mode or fallback). Confirm the destination before continuing."
        case .automaticCopyBlocked:
            return "A secure or unknown target was detected, so the clipboard was NOT written automatically. You can copy explicitly if you choose."
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
            .cancelled, .failed:
            return "Nothing was inserted."
        }
    }

    /// Retry must capture FRESH evidence — never reuse a stale validation.
    public var allowsRetry: Bool {
        switch outcome {
        case .targetChanged, .targetGone, .notEditable, .deadlineExceeded:
            return true
        case .targetUnknown, .secureTarget:
            return false  // retry cannot fix missing permission or a secure field
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .automaticCopy, .automaticCopyBlocked,
            .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
            .cancelled, .failed:
            return false
        }
    }

    /// Explicit copy is always available (with a warning for secure/unknown).
    public var allowsCopy: Bool { true }

    public var allowsDiscard: Bool { true }

    /// Missing-AX (targetUnknown) gets a direct settings link.
    public var allowsOpenAccessibilitySettings: Bool {
        outcome == .targetUnknown
    }

    /// Secure/unknown copy must be clearly warned about the global clipboard.
    public var shouldWarnBeforeCopy: Bool {
        switch outcome {
        case .secureTarget, .targetUnknown: return true
        default: return false
        }
    }

    /// Non-green state by construction: uncertain outcomes never auto-paste,
    /// auto-copy or auto-dismiss as success.
    public var isUncertain: Bool { outcome.isUncertain }

    public var isExpired: Bool {
        clearReason == .expired
    }

    public func expired(nowNanos: UInt64) -> Bool {
        clearReason == nil && nowNanos &- createdAtNanos >= retentionNanosAhead
    }

    /// Single-shot action consumption; terminal afterwards.
    public mutating func consume(_ action: InsertionReviewAction, nowNanos: UInt64) -> Bool {
        guard clearReason == nil else { return false }
        guard nowNanos &- createdAtNanos < retentionNanosAhead else {
            clearReason = .expired
            return false
        }
        switch action {
        case .retryValidation: guard allowsRetry else { return false }
        case .explicitCopy: guard allowsCopy else { return false }
        case .discard: guard allowsDiscard else { return false }
        case .openAccessibilitySettings: guard allowsOpenAccessibilitySettings else { return false }
        }
        consumedAction = action
        switch action {
        case .retryValidation: clearReason = .retriedWithFreshIntent
        case .explicitCopy: clearReason = .userCopied
        case .discard: clearReason = .userDiscarded
        case .openAccessibilitySettings: clearReason = nil
        }
        return true
    }

    public mutating func clear(_ reason: ClearReason) {
        guard clearReason == nil else { return }
        clearReason = reason
    }
}
