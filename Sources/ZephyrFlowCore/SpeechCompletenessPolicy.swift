import Foundation

/// Review R3.1: the completeness decision for a speech engine result is a
/// pure, testable policy. An errored partial is NEVER complete.
public enum SpeechCompletenessPolicy {
    /// Determine completeness from the final-event/error/usable-text signals.
    /// - Returns: `.complete` only when a genuine final event arrived with no
    ///   error AND usable text; otherwise `.partial` (usable text) or
    ///   `.degraded` (no text).
    public static func completeness(
        sawFinal: Bool,
        error: String?,
        hasText: Bool
    ) -> EngineResultCompleteness {
        if sawFinal && error == nil && hasText { return .complete }
        if hasText { return .partial }
        return .degraded
    }

    /// Warnings matching the completeness decision.
    public static func warnings(
        sawFinal: Bool,
        error: String?,
        hasText: Bool
    ) -> [EngineWarning] {
        if sawFinal && error == nil && hasText { return [] }
        if hasText { return [.partialFallback] }
        return [.captureDegraded]
    }
}
