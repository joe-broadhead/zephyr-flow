import Foundation

// JOE-2290: transactional Launch at Login — reflects authoritative
// SMAppService state; never persists a desired value after registration/
// unregistration failed.

public enum LaunchAtLoginState: String, Codable, CaseIterable, Sendable, Equatable {
    case registered
    case notRegistered
    case requiresApproval
    case notFound  // unpackaged development build
    case denied
    case unsupported
    case stale  // system registration diverges from settings
}

public enum LaunchAtLoginTransactionState: String, Codable, CaseIterable, Sendable, Equatable {
    case idle
    case pending  // external change in flight; UI shows pending
    case applied  // external change succeeded + verified
    case rolledBack  // external change failed; desired value reverted
}

public struct LaunchAtLoginTransaction: Sendable, Equatable {
    public private(set) var state: LaunchAtLoginTransactionState = .idle
    public private(set) var desiredEnabled: Bool?
    public private(set) var verifiedStatus: LaunchAtLoginState?
    public private(set) var rollbackReason: String?

    public init() {}

    /// Enter the pending state with the desired value (UI shows pending;
    /// settings JSON is NOT yet committed).
    public mutating func begin(desiredEnabled: Bool) {
        guard state == .idle else { return }
        state = .pending
        self.desiredEnabled = desiredEnabled
    }

    /// The external change succeeded and the re-read status matches the
    /// desired state => commit (durable settings + UI converge).
    public mutating func commit(verifiedStatus: LaunchAtLoginState) {
        guard state == .pending else { return }
        state = .applied
        self.verifiedStatus = verifiedStatus
    }

    /// Roll back: the external change failed or the status did not converge —
    /// no false enabled/disabled setting is persisted.
    public mutating func rollback(reason: String) {
        guard state == .pending || state == .applied else { return }
        state = .rolledBack
        self.rollbackReason = reason
        self.desiredEnabled = nil
    }

    public var isPending: Bool { state == .pending }

    /// Convergence rule: status matches the desired value.
    public static func statusConverges(
        status: LaunchAtLoginState,
        desiredEnabled: Bool
    ) -> Bool {
        switch status {
        case .registered: return desiredEnabled
        case .notRegistered: return !desiredEnabled
        // Approval pending / not-found / denied / unsupported / stale are
        // NOT convergence — they must surface to the user, not commit.
        case .requiresApproval, .notFound, .denied, .unsupported, .stale:
            return false
        }
    }
}
