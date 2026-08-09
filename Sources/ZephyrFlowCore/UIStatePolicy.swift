import Foundation

// JOE-2284: truthful panel/menu/history rendering policy.
//
// Deterministic mapping from (EngineResultCompleteness × FlowOutcomeStatus ×
// InsertionOutcome) to a panel presentation. Green "inserted" success requires
// a complete transcript AND a verifiedInserted outcome; every uncertain or
// fallback state uses distinct language and persistent (non-auto-dismiss)
// presentation. Color is never the only signal — every state carries a
// VoiceOver label and symbol.

public enum PanelSemanticState: String, Codable, CaseIterable, Sendable, Equatable {
    case verifiedSuccess
    case unverifiedPosted
    case review
    case warning
    case error
    case processing
    case neutral
}

public struct PanelPresentation: Sendable, Equatable {
    public let semantic: PanelSemanticState
    /// User-visible headline (never technical AX/engine jargon).
    public let title: String?
    /// Persistent until resolved/dismissed when autoDismiss is nil.
    public let message: String?
    public let autoDismissAfterNanos: UInt64?
    /// Semantic color token (green/amber/red/neutral) — UI must ALSO set the
    /// VoiceOver label; color is never the only signal.
    public let colorToken: String
    public let voiceOverLabel: String
    public let symbol: String

    public init(
        semantic: PanelSemanticState, title: String?, message: String?,
        autoDismissAfterNanos: UInt64?, colorToken: String,
        voiceOverLabel: String, symbol: String
    ) {
        self.semantic = semantic
        self.title = title
        self.message = message
        self.autoDismissAfterNanos = autoDismissAfterNanos
        self.colorToken = colorToken
        self.voiceOverLabel = voiceOverLabel
        self.symbol = symbol
    }

    public var isPersistent: Bool { autoDismissAfterNanos == nil }
}

/// One tested policy: every EngineResult × FlowOutcome × InsertionOutcome
/// combination maps to a truthful presentation. No uncertain case shares the
/// verified-success presentation.
public enum UIStatePolicy {
    public static func presentation(
        engineCompleteness: EngineResultCompleteness,
        flowStatus: FlowOutcomeStatus,
        insertion: InsertionOutcome
    ) -> PanelPresentation {
        // Engine uncertainty dominates: partial/degraded/truncated transcripts
        // can NEVER show verified success, and must persist (no auto-dismiss).
        switch engineCompleteness {
        case .partial:
            return PanelPresentation(
                semantic: .warning,
                title: "Partial transcript",
                message: "The audio was only partially understood. Review before using.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Warning: partial transcript, review required",
                symbol: "exclamationmark.triangle")
        case .degraded:
            return PanelPresentation(
                semantic: .error,
                title: "Capture degraded",
                message: "Audio capture was incomplete. Nothing was inserted.",
                autoDismissAfterNanos: nil,
                colorToken: "red",
                voiceOverLabel: "Error: audio capture degraded",
                symbol: "xmark.octagon")
        case .truncated:
            return PanelPresentation(
                semantic: .warning,
                title: "Transcript truncated",
                message: "The audio was cut short. Review before using.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Warning: transcript truncated",
                symbol: "scissors")
        case .complete:
            break
        }

        // Flow fallback/rejection is visible when it materially changes the
        // requested style (status != accepted).
        if flowStatus != .accepted {
            return PanelPresentation(
                semantic: .warning,
                title: "Simplified formatting",
                message: "The requested style was not fully applied. Text was kept conservative.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Warning: requested style not fully applied",
                symbol: "text.badge.minus")
        }

        // Insertion confidence.
        switch insertion {
        case .verifiedInserted:
            return PanelPresentation(
                semantic: .verifiedSuccess,
                title: "Inserted",
                message: nil,
                autoDismissAfterNanos: 1_800_000_000,
                colorToken: "green",
                voiceOverLabel: "Success: text inserted",
                symbol: "checkmark.circle.fill")
        case .explicitlyCopiedByUser:
            return PanelPresentation(
                semantic: .verifiedSuccess,
                title: "Copied to clipboard",
                message: nil,
                autoDismissAfterNanos: 1_800_000_000,
                colorToken: "green",
                voiceOverLabel: "Copied to clipboard",
                symbol: "doc.on.doc.fill")
        case .eventPostedUnverified:
            // Distinct language — NEVER "Inserted".
            return PanelPresentation(
                semantic: .unverifiedPosted,
                title: "Paste sent — verify destination",
                message: "The paste command was sent but the app did not confirm receipt.",
                autoDismissAfterNanos: 3_000_000_000,
                colorToken: "amber",
                voiceOverLabel: "Paste sent, verify the destination",
                symbol: "paperplane")
        case .automaticCopy:
            return PanelPresentation(
                semantic: .review,
                title: "Copied to clipboard (automatic) — verify",
                message: "The clipboard was written automatically. Confirm the destination before continuing.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Copied to clipboard automatically, please verify",
                symbol: "doc.on.doc")
        case .automaticCopyBlocked:
            return PanelPresentation(
                semantic: .review,
                title: "Automatic clipboard blocked",
                message:
                    "A secure or unknown target was detected, so nothing was copied automatically. Review before copying.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Automatic clipboard blocked, review before copying",
                symbol: "exclamationmark.triangle")
        case .targetChanged:
            return PanelPresentation(
                semantic: .review,
                title: "Target changed",
                message: "The app or window changed while you spoke. Nothing was inserted.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Review: target changed, nothing inserted",
                symbol: "arrow.triangle.swap")
        case .targetGone:
            return PanelPresentation(
                semantic: .review,
                title: "Target closed",
                message: "The app you were typing into closed. Nothing was inserted.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Review: target closed, nothing inserted",
                symbol: "xmark.circle")
        case .targetUnknown:
            return PanelPresentation(
                semantic: .review,
                title: "Target could not be confirmed",
                message: "Allow Accessibility to insert automatically, or copy explicitly.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Review: target could not be confirmed",
                symbol: "questionmark.circle")
        case .secureTarget:
            return PanelPresentation(
                semantic: .review,
                title: "Secure field detected",
                message: "Nothing was pasted or saved. Copy explicitly if you choose.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Review: secure field, explicit copy only",
                symbol: "lock.fill")
        case .notEditable:
            return PanelPresentation(
                semantic: .review,
                title: "Field is not editable",
                message: "Nothing was inserted.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Review: field not editable",
                symbol: "pencil.slash")
        case .clipboardNotRestoredBecauseChanged:
            return PanelPresentation(
                semantic: .warning,
                title: "Clipboard left as-is",
                message: "The clipboard changed while pasting, so your content was kept.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Warning: clipboard not restored because it changed",
                symbol: "doc.on.clipboard")
        case .clipboardRestoreFailed:
            return PanelPresentation(
                semantic: .error,
                title: "Could not restore clipboard",
                message: "Your previous clipboard content could not be restored.",
                autoDismissAfterNanos: nil,
                colorToken: "red",
                voiceOverLabel: "Error: clipboard could not be restored",
                symbol: "exclamationmark.triangle")
        case .deadlineExceeded:
            return PanelPresentation(
                semantic: .warning,
                title: "Timed out",
                message: "The target did not respond in time. Nothing was inserted.",
                autoDismissAfterNanos: nil,
                colorToken: "amber",
                voiceOverLabel: "Warning: timed out waiting for target",
                symbol: "timer")
        case .cancelled:
            return PanelPresentation(
                semantic: .neutral,
                title: "Cancelled",
                message: nil,
                autoDismissAfterNanos: 1_200_000_000,
                colorToken: "neutral",
                voiceOverLabel: "Cancelled",
                symbol: "xmark")
        case .failed(let msg):
            return PanelPresentation(
                semantic: .error,
                title: "Not inserted",
                message: msg,
                autoDismissAfterNanos: nil,
                colorToken: "red",
                voiceOverLabel: "Error: not inserted",
                symbol: "xmark.octagon")
        }
    }

    /// Whether a combination is permitted to render as verified success.
    public static func isVerifiedSuccess(
        engineCompleteness: EngineResultCompleteness,
        flowStatus: FlowOutcomeStatus,
        insertion: InsertionOutcome
    ) -> Bool {
        presentation(
            engineCompleteness: engineCompleteness,
            flowStatus: flowStatus,
            insertion: insertion
        ).semantic == .verifiedSuccess
    }
}
