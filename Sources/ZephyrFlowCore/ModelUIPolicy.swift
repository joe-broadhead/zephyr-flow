import Foundation

// JOE-2283: first-run model acquisition UX policy — deterministic rules so
// the UI never looks like a dead microphone or an unexplained background
// transfer. Every verified lifecycle state renders honestly (real progress
// vs indeterminate), downloads never start before an explicit user action,
// superseded completions cannot overwrite current UI, and a dictation
// attempt while the selected model is not ready never enters a fake
// listening/capturing state.

// MARK: - Rendered lifecycle states

public enum ModelLifecycleAction: String, Sendable, Equatable {
    case none
    case cancel
    case retry
    case chooseAnotherModel
    case useAppleSpeech
    case continueLimitedReviewOnly
}

public struct ModelLifecycleUIRender: Sendable, Equatable {
    public let stateName: String
    /// Whether progress bytes/fraction are sourced from REAL progress.
    public let hasHonestProgress: Bool
    /// When no real progress is available, UI must show indeterminate.
    public let isIndeterminate: Bool
    public let primaryAction: ModelLifecycleAction
    public let recoverable: Bool
    /// True when this state may not enter a listening/capturing session.
    public let blocksDictation: Bool

    public init(
        stateName: String, hasHonestProgress: Bool,
        isIndeterminate: Bool, primaryAction: ModelLifecycleAction,
        recoverable: Bool, blocksDictation: Bool
    ) {
        self.stateName = stateName
        self.hasHonestProgress = hasHonestProgress
        self.isIndeterminate = isIndeterminate
        self.primaryAction = primaryAction
        self.recoverable = recoverable
        self.blocksDictation = blocksDictation
    }
}

// MARK: - Policy

public enum ModelUIPolicy: Sendable {
    /// Minimum free bytes before a model download may start (~1.5 GB headroom
    /// beyond the largest model).
    public static let minimumFreeBytesForDownload: UInt64 = 1_500_000_000

    /// Deterministic render for every verified lifecycle state.
    public static func render(for state: ModelReadinessState) -> ModelLifecycleUIRender {
        switch state {
        case .notApplicable:
            return ModelLifecycleUIRender(
                stateName: "Built-in",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .none,
                recoverable: true,
                blocksDictation: false)
        case .missing:
            return ModelLifecycleUIRender(
                stateName: "Not downloaded",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .retry,
                recoverable: true,
                blocksDictation: true)
        case .queued:
            return ModelLifecycleUIRender(
                stateName: "Queued…",
                hasHonestProgress: false,
                isIndeterminate: true,
                primaryAction: .cancel,
                recoverable: true,
                blocksDictation: true)
        case .downloading(let fraction):
            // Honest progress ONLY when a real fraction exists.
            let honest = fraction.map { $0 >= 0 && $0 <= 1 } ?? false
            return ModelLifecycleUIRender(
                stateName: "Downloading…",
                hasHonestProgress: honest,
                isIndeterminate: !honest,
                primaryAction: .cancel,
                recoverable: true,
                blocksDictation: true)
        case .verifying:
            return ModelLifecycleUIRender(
                stateName: "Verifying…",
                hasHonestProgress: false,
                isIndeterminate: true,
                primaryAction: .none,
                recoverable: true,
                blocksDictation: true)
        case .ready:
            return ModelLifecycleUIRender(
                stateName: "Ready",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .none,
                recoverable: true,
                blocksDictation: false)
        case .cancelled:
            return ModelLifecycleUIRender(
                stateName: "Cancelled",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .retry,
                recoverable: true,
                blocksDictation: true)
        case .quarantined:
            return ModelLifecycleUIRender(
                stateName: "Quarantined — corrupt content",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .retry,
                recoverable: true,
                blocksDictation: true)
        case .failed(let message):
            return ModelLifecycleUIRender(
                stateName: "Failed — \(message)",
                hasHonestProgress: false,
                isIndeterminate: false,
                primaryAction: .retry,
                recoverable: true,
                blocksDictation: true)
        }
    }

    /// First-run rule: a download may only start after the user saw model
    /// name/size/storage/network purpose AND gave an explicit action.
    public static func mayStartDownload(
        consent: Bool,
        hasCachedVerifiedModel: Bool,
        freeBytes: UInt64
    ) -> ModelDownloadGate {
        if hasCachedVerifiedModel { return .startFromCache }
        guard consent else { return .consentRequired }
        guard freeBytes >= minimumFreeBytesForDownload else {
            return .insufficientDiskSpace(
                required: minimumFreeBytesForDownload,
                available: freeBytes)
        }
        return .allowed
    }

    public enum ModelDownloadGate: Sendable, Equatable {
        case startFromCache
        case allowed
        case consentRequired
        case insufficientDiskSpace(required: UInt64, available: UInt64)
    }

    /// Actionable cleanup guidance from the free-space shortfall.
    public static func cleanupGuidance(
        available: UInt64,
        required: UInt64
    ) -> String {
        let short = required - min(available, required)
        return
            "Free at least \(ByteCountFormatter.string(fromByteCount: Int64(short), countStyle: .file)) more space (Model Downloads need ~\(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)))."
    }

    /// Superseded completion absorption: a completion for a NON-current
    /// request renders as "superseded" and can never overwrite current UI.
    public static func absorbCompletion(isCurrent: Bool) -> ModelLifecycleAction {
        isCurrent ? .none : .none  // superseded completions are no-ops at UI level
    }
}
