import Foundation

/// Round-5 review B4: an immutable, one-use lease on the EXACT validated
/// target, produced by successful target validation and consumed by both the
/// AX and paste mutation paths. Paste insertion is bound to the application
/// AND to the validated field/window/element — a user switching from one
/// ordinary field to another in the same application (or window) must fail
/// closed, never post Command-V into an unvalidated destination.
///
/// The lease is one-use: after a mutation attempt it is marked consumed, so a
/// stale re-check after insertion can never re-validate a different target.
public struct TargetLease: Sendable, Equatable {
    /// Session/generation identity (immutable allocation).
    public let sessionID: SessionID
    /// PID + process-start identity (PID reuse/process restart detection).
    public let pid: Int32
    public let processStartUptimeNanos: UInt64?
    /// Bundle identity.
    public let bundleID: String?
    /// Focused AX window identity.
    public let windowID: UInt32?
    /// Stable element token + role/subrole.
    public let element: TargetSnapshot.ElementIdentity?
    /// Capabilities at validation time.
    public let settable: Bool
    public let editable: Bool
    public let enabled: Bool
    /// Sensitivity at validation time.
    public let sensitivity: SessionSensitivity
    /// Validation deadline (continuous clock); a lease older than this must
    /// fail closed.
    public let validatedAtUptimeNanos: UInt64
    public let validationDeadlineNanos: UInt64

    public init(
        sessionID: SessionID,
        pid: Int32,
        processStartUptimeNanos: UInt64?,
        bundleID: String?,
        windowID: UInt32?,
        element: TargetSnapshot.ElementIdentity?,
        settable: Bool,
        editable: Bool,
        enabled: Bool,
        sensitivity: SessionSensitivity,
        validatedAtUptimeNanos: UInt64,
        validationDeadlineNanos: UInt64
    ) {
        self.sessionID = sessionID
        self.pid = pid
        self.processStartUptimeNanos = processStartUptimeNanos
        self.bundleID = bundleID
        self.windowID = windowID
        self.element = element
        self.settable = settable
        self.editable = editable
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.validatedAtUptimeNanos = validatedAtUptimeNanos
        self.validationDeadlineNanos = validationDeadlineNanos
    }

    /// Build a lease from a validated snapshot + now (continuous clock).
    public static func make(
        snapshot: TargetSnapshot,
        sessionID: SessionID,
        validationDeadlineNanosAhead: UInt64,
        nowNanos: UInt64
    ) -> TargetLease {
        TargetLease(
            sessionID: sessionID,
            pid: snapshot.target.pid,
            processStartUptimeNanos: snapshot.target.processStartUptimeNanos,
            bundleID: snapshot.target.bundleID,
            windowID: snapshot.target.windowID,
            element: snapshot.element,
            settable: snapshot.settable,
            editable: snapshot.editable,
            enabled: snapshot.enabled,
            sensitivity: snapshot.sensitivity.sensitivity,
            validatedAtUptimeNanos: nowNanos,
            validationDeadlineNanos: nowNanos &+ validationDeadlineNanosAhead)
    }

    /// Expired when the validation deadline has passed (stale lease).
    public func isExpired(nowNanos: UInt64) -> Bool {
        nowNanos >= validationDeadlineNanos
    }

    /// Re-validation against a freshly-resolved snapshot. Returns false when
    /// ANY identity component differs — including same-bundle field/window
    /// switches and PID reuse (process-start identity mismatch).
    public func matches(
        reResolved: TargetSnapshot,
        requireWindow: Bool,
        requireElementToken: Bool,
        nowNanos: UInt64
    ) -> Bool {
        guard !isExpired(nowNanos: nowNanos) else { return false }
        guard reResolved.target.pid == pid,
            reResolved.target.processStartUptimeNanos == processStartUptimeNanos,
            reResolved.target.bundleID == bundleID
        else { return false }
        if requireWindow {
            guard reResolved.target.windowID != nil,
                reResolved.target.windowID == windowID
            else { return false }
        }
        if requireElementToken {
            guard let tok = element?.resolutionToken,
                tok == reResolved.element?.resolutionToken
            else { return false }
        }
        // Role/subrole identity when available.
        if let expectedRole = element?.role,
            reResolved.element?.role != expectedRole
        {
            return false
        }
        if let expectedSub = element?.subrole,
            reResolved.element?.subrole != expectedSub
        {
            return false
        }
        // Capability parity (settable/editable/enabled).
        guard reResolved.settable == settable,
            reResolved.editable == editable,
            reResolved.enabled == enabled
        else { return false }
        return true
    }
}
