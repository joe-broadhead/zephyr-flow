import Foundation

// JOE-2249: bind capture callbacks to an immutable session + engine snapshot.
//
// Deterministic, AppKit-free gate that rejects any async callback that outlived
// its session (cancellation / terminal outcome / engine replacement). The app
// layer captures a `SessionEngineBinding` when capture starts and validates
// every delayed callback against it — never dereferencing mutable controller
// engine state inside a delayed task.

/// Immutable identity of the engine instance a session started with.
public struct EngineToken: Sendable, Equatable, Hashable {
    public let value: String

    public init(value: String = UUID().uuidString) {
        self.value = value
    }
}

/// Engine kind (content-free classification for routing/logs).
public enum EngineKind: String, Codable, Sendable, Equatable {
    case whisper
    case appleSpeech
}

/// Immutable session-owned binding captured at capture start.
public struct SessionEngineBinding: Sendable, Equatable {
    public let sessionID: SessionID
    public let engineToken: EngineToken
    public let engineKind: EngineKind

    public init(sessionID: SessionID, engineToken: EngineToken, engineKind: EngineKind) {
        self.sessionID = sessionID
        self.engineToken = engineToken
        self.engineKind = engineKind
    }
}

/// Why a callback gate closed.
public enum CallbackGateReason: String, Codable, Sendable, Equatable {
    case cancelled
    case terminalOutcome
    case engineReplaced
    case drainCompleted
}

/// Single-shot gate: callbacks are accepted while open; any close reason makes
/// every later callback invalid (rejected). No callback may outlive its
/// session/engine.
public struct CallbackGate: Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case open
        case closed
    }

    public private(set) var state: State = .open
    public private(set) var closeReason: CallbackGateReason?

    public init() {}

    /// Accepts a callback only when the gate is open AND the binding matches
    /// the current session + engine token (engine replacement closes it).
    public func accepts(binding: SessionEngineBinding,
                        currentSessionID: SessionID?,
                        currentEngineToken: EngineToken) -> Bool {
        guard state == .open else { return false }
        guard let currentSessionID, binding.sessionID == currentSessionID else { return false }
        return binding.engineToken == currentEngineToken
    }

    /// Close exactly once (idempotent after the first close).
    public mutating func close(reason: CallbackGateReason) {
        guard state == .open else { return }
        state = .closed
        closeReason = reason
    }

    public var isClosed: Bool { state == .closed }
}
