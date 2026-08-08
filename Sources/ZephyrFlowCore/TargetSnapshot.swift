import Foundation

/// TargetSnapshot: immutable evidence captured BEFORE any Zephyr UI
/// interaction that identifies the intended insertion target and its
/// sensitivity (contract: JOE-2267; validation logic in JOE-2268).
///
/// The snapshot never copies field contents unless explicitly approved;
/// selected-range metadata is positional only.
public struct TargetSnapshot: Sendable, Equatable {
    public struct Identity: Sendable, Equatable {
        /// Target process identifier at capture time.
        public let pid: Int32
        /// Bundle identifier, when resolvable.
        public let bundleID: String?
        /// Audit/process start-time identity to detect PID reuse.
        public let processStartUptimeNanos: UInt64?
        /// Global window id (CGWindowID, stored as UInt32) atop the AX element, when available.
        public let windowID: UInt32?
        /// Bundle/version of the target application.
        public let appVersion: String?

        public init(pid: Int32,
                    bundleID: String?,
                    processStartUptimeNanos: UInt64?,
                    windowID: UInt32?,
                    appVersion: String?) {
            self.pid = pid
            self.bundleID = bundleID
            self.processStartUptimeNanos = processStartUptimeNanos
            self.windowID = windowID
            self.appVersion = appVersion
        }
    }

    /// Focused AX element identity (or a documented re-resolution token).
    public struct ElementIdentity: Sendable, Equatable {
        public let role: String
        public let subrole: String?
        /// A stable application-scoped token when the AX API can provide one.
        public let resolutionToken: String?

        public init(role: String, subrole: String?, resolutionToken: String?) {
            self.role = role
            self.subrole = subrole
            self.resolutionToken = resolutionToken
        }
    }

    public let sessionID: SessionID
    /// Continuous-clock capture instant.
    public let capturedAtUptimeNanos: UInt64
    public let target: Identity
    public let element: ElementIdentity?
    /// Capabilities the target exhibited at capture time.
    public let settable: Bool
    public let editable: Bool
    public let enabled: Bool
    /// Selected-text metadata WITHOUT copying field contents.
    public let selectionRange: Range<Int>?
    public let sensitivity: SensitivityAssessment

    public init(sessionID: SessionID,
                capturedAtUptimeNanos: UInt64,
                target: Identity,
                element: ElementIdentity?,
                settable: Bool,
                editable: Bool,
                enabled: Bool,
                selectionRange: Range<Int>?,
                sensitivity: SensitivityAssessment) {
        self.sessionID = sessionID
        self.capturedAtUptimeNanos = capturedAtUptimeNanos
        self.target = target
        self.element = element
        self.settable = settable
        self.editable = editable
        self.enabled = enabled
        self.selectionRange = selectionRange
        self.sensitivity = sensitivity
    }

    /// A snapshot may never identify Zephyr itself or an ignored system
    /// process as the target. This predicate is the contract surface; the
    /// resolver layer supplies the process list (JOE-2268).
    public func isUsableTarget(zephyrPIDs: Set<Int32>, ignoredSystemPIDs: Set<Int32>) -> Bool {
        !zephyrPIDs.contains(target.pid) && !ignoredSystemPIDs.contains(target.pid)
    }

    /// Missing AX evidence yields unknown sensitivity and low target confidence.
    public var targetConfidence: TargetConfidence {
        guard element != nil else { return .unknown }
        if target.windowID != nil { return .high }
        return .medium
    }
}

/// Level of certainty that the snapshot will revalidate to the same target.
public enum TargetConfidence: Int8, Sendable, Equatable {
    case unknown = 0
    case low = 1
    case medium = 2
    case high = 3
}
