import Foundation

// JOE-2253: Apple Speech tokenized callbacks + event-driven finalization.
//
// Deterministic, AppKit/Speech-free model: a unique recognition token per
// start; callbacks with a stale token are ignored; finalization is driven by
// a single final event (final result / terminal error / cancellation /
// deadline) instead of polling; empty final callbacks preserve the latest
// usable partial with warning provenance; waiters resume exactly once.

/// Token for one recognition run (unique per start).
public struct RecognitionToken: Sendable, Equatable, Hashable {
    public let value: String
    public init(value: String = UUID().uuidString) {
        self.value = value
    }
}

/// Controlled finalization event (content-free; no transcript text).
public enum SpeechFinalEvent: Sendable, Equatable {
    /// Final result received (isFinal true). `hasText` indicates whether the
    /// engine returned a usable final text (or an empty final).
    case finalResult(hasText: Bool)
    /// Terminal error (friendly, content-free reason).
    case terminalError(code: Int32, friendly: String)
    /// Explicit cancellation.
    case cancelled
    /// Deadline reached while waiting for the final event.
    case deadlineExceeded
}

/// Outcome classification for observability (no transcript bodies).
public enum SpeechFinalizationOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case finalResult
    case emptyFinalWithPartial    // empty final; latest partial preserved
    case terminalErrorWithPartial // error; partial preserved
    case terminalErrorNoText
    case cancelled
    case deadlineWithPartial      // deadline; partial preserved (never complete)
    case deadlineNoText
}

/// Tracks one recognition run: token identity, single final event, partial
/// preservation on empty finals, and exactly-once waiter resume.
public struct SpeechRecognitionTracker: Sendable, Equatable {
    public private(set) var currentToken: RecognitionToken?
    public private(set) var finalEvent: SpeechFinalEvent?
    public private(set) var latestPartial: String?
    public private(set) var staleCallbackRejections: UInt64 = 0
    public private(set) var resumedOnce = false

    public init() {}

    public mutating func start(token: RecognitionToken) {
        currentToken = token
        finalEvent = nil
        latestPartial = nil
        resumedOnce = false
    }

    /// A callback is current only when its token matches AND no final event
    /// has fired yet (session not terminal).
    public func isCurrent(token: RecognitionToken) -> Bool {
        currentToken == token && finalEvent == nil
    }

    /// Partial result: preserves latest non-empty text; ignores stale tokens.
    public mutating func notePartial(token: RecognitionToken, text: String) -> Bool {
        guard isCurrent(token: token) else {
            staleCallbackRejections += 1
            return false
        }
        if !text.isEmpty {
            latestPartial = text
        }
        return true
    }

    /// Final result callback: if empty and we have a partial, PRESERVE the
    /// partial (empty finals commonly arrive on cancel/end) with warning
    /// provenance; otherwise record the final event. Single-shot.
    public mutating func noteFinal(token: RecognitionToken, hasText: Bool) -> SpeechFinalizationOutcome {
        guard isCurrent(token: token) else {
            staleCallbackRejections += 1
            return .cancelled
        }
        if !hasText, let _ = latestPartial {
            finalEvent = .finalResult(hasText: false)
            return .emptyFinalWithPartial
        }
        finalEvent = .finalResult(hasText: hasText)
        return hasText ? .finalResult : .terminalErrorNoText
    }

    /// Terminal error: keep partial if present (with provenance), else no
    /// text outcome. Single-shot.
    public mutating func noteError(token: RecognitionToken, code: Int32, friendly: String) -> SpeechFinalizationOutcome {
        guard isCurrent(token: token) else {
            staleCallbackRejections += 1
            return .cancelled
        }
        if latestPartial != nil {
            finalEvent = .terminalError(code: code, friendly: friendly)
            return .terminalErrorWithPartial
        }
        finalEvent = .terminalError(code: code, friendly: friendly)
        return .terminalErrorNoText
    }

    /// Cancellation: single-shot terminal.
    public mutating func cancel(token: RecognitionToken) -> SpeechFinalizationOutcome {
        guard isCurrent(token: token) else {
            staleCallbackRejections += 1
            return .cancelled
        }
        finalEvent = .cancelled
        return .cancelled
    }

    /// Deadline: a non-empty partial at deadline is ONLY partial/degraded —
    /// never complete. Single-shot.
    public mutating func noteDeadline() -> SpeechFinalizationOutcome {
        guard finalEvent == nil else { return .cancelled }
        finalEvent = .deadlineExceeded
        return latestPartial != nil ? .deadlineWithPartial : .deadlineNoText
    }

    /// Waiter resume must happen exactly once across all terminal paths.
    public mutating func markResumed() -> Bool {
        guard !resumedOnce else { return false }
        resumedOnce = true
        return true
    }
}
