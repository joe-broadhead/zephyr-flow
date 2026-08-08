import Foundation

// JOE-2256: generation-safe model selection + preload. A monotonic request ID
// per load; stale completions are rejected (typed superseded/cancelled) and
// can never overwrite a current ready/failed state or show an obsolete error
// banner. Sessions capture their engine identity at start (JOE-2249), so
// switching models mid-dictation never affects the active session.

// MARK: - Typed outcomes

public enum ModelLoadOutcome: Sendable, Equatable {
    case ready(model: ModelIdentifier)
    case failed(model: ModelIdentifier, message: String)
    case cancelled(model: ModelIdentifier)
    /// A newer selection superseded this load; its completion is ignored.
    case superseded(model: ModelIdentifier, byRequestID: UInt64)
}

// MARK: - Selection tracker (deterministic value type)

/// Monotonic model-selection generation. Only the CURRENT request may publish
/// readiness/banner/error state; everything older is a typed non-event.
public struct ModelSelectionTracker: Sendable, Equatable {
    public private(set) var currentRequestID: UInt64 = 0
    public private(set) var currentModel: ModelIdentifier?
    /// Snapshot of settings at request start (consent etc.).
    public private(set) var currentSettings: ModelSelectionSettings?
    private var nextRequestID: UInt64 = 0

    public init() {}

    public struct ModelSelectionSettings: Sendable, Equatable {
        public let allowModelDownloads: Bool
        public let localOnlyMode: Bool
        public init(allowModelDownloads: Bool, localOnlyMode: Bool) {
            self.allowModelDownloads = allowModelDownloads
            self.localOnlyMode = localOnlyMode
        }
    }

    /// Submit a new selection; supersedes any in-flight request.
    @discardableResult
    public mutating func submit(model: ModelIdentifier,
                                settings: ModelSelectionSettings) -> UInt64 {
        nextRequestID += 1
        currentRequestID = nextRequestID
        currentModel = model
        currentSettings = settings
        return currentRequestID
    }

    public func isCurrent(_ requestID: UInt64) -> Bool {
        requestID == currentRequestID
    }

    /// Decide what a completion MAY publish. Stale completions become typed
    /// superseded events; the current failed/ready state is untouched.
    public mutating func acceptCompletion(requestID: UInt64,
                                          model: ModelIdentifier,
                                          outcome: ModelLoadOutcome,
                                          nowNanos: UInt64 = 0) -> ModelLoadOutcome {
        guard isCurrent(requestID) else {
            return .superseded(model: model, byRequestID: currentRequestID)
        }
        return outcome
    }

    /// A newer selection superseded this load; its completion is ignored.
    public mutating func cancelCurrent() {
        // Marks the current request as no longer current (no model).
        nextRequestID += 1
        currentRequestID = nextRequestID
        currentModel = nil
        currentSettings = nil
    }

    /// Session-start guard: a session may only start against an engine whose
    /// selection is the CURRENT one (never a finished-obsolete load).
    public func allowsSessionStart(model: ModelIdentifier) -> Bool {
        currentModel == model
    }
}
