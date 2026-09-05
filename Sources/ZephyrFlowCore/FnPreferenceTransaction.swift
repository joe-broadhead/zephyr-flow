import Foundation

// JOE-2286: exact + transactional Fn/Globe preference override.
//
// The production default path NEVER touches the system preference. The
// optional single-Fn override only begins after explicit experimental
// opt-in AND successful hotkey/tap preparation; it snapshots the EXACT
// prior state (presence, value, CF type, suite/domain), persists a
// versioned transaction record BEFORE mutation, acknowledges
// apply/restore status, restores exactly the original state (never an
// unconditional key removal after a value was present), verifies by
// read-back, and on restore failure disables Fn capture + surfaces a
// persistent recovery action without re-applying automatically. Crash
// recovery on next launch is idempotent and never mistakes a COMPLETED
// transaction for an ACTIVE override.

public enum FnPreferenceStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case idle  // no override ever started
    case pendingApply  // journal written; mutation may have happened before crash
    case applied  // override active (record is authoritative)
    case pendingRestore  // restore started (never auto-reapplies)
    case restored  // COMPLETED — not an active override
    case failedRestore  // restore failed -> disable capture + recovery
}

public struct FnPreferenceSnapshot: Codable, Equatable, Sendable {
    /// Exact prior state of the `AppleFnUsageType` key.
    public var keyPresent: Bool
    public var value: Int64?
    /// CF type tag of the stored value (e.g. CFNumber/CFString), or nil
    /// when absent. Captured so restore reproduces the exact type.
    public var cfTypeTag: String?
    public var suiteName: String
    public var keyName: String
    /// Version-2 binary property-list payload preserves unexpected values and
    /// their CF types. Legacy present-value records lack sufficient evidence
    /// for exact restoration and must not guess a value or remove the key.
    public var encodedValue: Data?

    public init(
        keyPresent: Bool, value: Int64?, cfTypeTag: String?,
        suiteName: String = "com.apple.HIToolbox",
        keyName: String = "AppleFnUsageType",
        encodedValue: Data? = nil
    ) {
        self.keyPresent = keyPresent
        self.value = value
        self.cfTypeTag = cfTypeTag
        self.suiteName = suiteName
        self.keyName = keyName
        self.encodedValue = encodedValue
    }

    public static let none = FnPreferenceSnapshot(keyPresent: false, value: nil, cfTypeTag: nil)
}

public struct FnPreferenceRecord: Codable, Equatable, Sendable {
    /// Journal schema version, not a transaction sequence or ownership token.
    public var version: Int
    public var status: FnPreferenceStatus
    public var snapshot: FnPreferenceSnapshot

    public init(version: Int, status: FnPreferenceStatus, snapshot: FnPreferenceSnapshot) {
        self.version = version
        self.status = status
        self.snapshot = snapshot
    }

    /// A failedRestore record is unresolved, not an active capture override.
    /// It needs explicit recovery and must not be re-applied automatically.
    public var isActiveOverride: Bool {
        switch status {
        case .applied, .pendingApply, .pendingRestore:
            return true
        case .idle, .restored, .failedRestore:
            return false
        }
    }
}

/// Deterministic state machine for the override transaction. Pure
/// (AppKit-free): `mutating` state + explicit fault injection for
/// apply/restore/crash at every step.
public struct FnPreferenceTransaction: Sendable, Equatable {
    public static let recordVersion = 2
    public var record: FnPreferenceRecord
    public private(set) var captureDisabled: Bool

    public init(record: FnPreferenceRecord) {
        self.record = record
        self.captureDisabled = record.status == .failedRestore
    }

    public init(snapshot: FnPreferenceSnapshot, version: Int = FnPreferenceTransaction.recordVersion) {
        self.init(
            record: FnPreferenceRecord(
                version: version, status: .idle, snapshot: snapshot))
    }

    /// Begin: write the versioned record (status pendingApply) BEFORE any
    /// mutation. Only allowed from idle.
    public mutating func beginApply() -> Bool {
        guard record.status == .idle else { return false }
        record.status = .pendingApply
        return true
    }

    /// Mark verified mutation success. Persistence acknowledgment is owned by
    /// the service, not this pure state machine.
    public mutating func markApplied(mutationSucceeded: Bool) {
        guard record.status == .pendingApply else { return }
        if mutationSucceeded {
            record.status = .applied
        } else {
            // Failed synchronization/read-back does NOT establish that no
            // mutation happened. Retain recoverable intent until restored.
            record.status = .pendingRestore
            captureDisabled = true
        }
    }

    /// Begin restore (never re-applies automatically).
    public mutating func beginRestore() -> Bool {
        guard [.applied, .pendingApply, .pendingRestore, .failedRestore].contains(record.status) else {
            return false
        }
        record.status = .pendingRestore
        return true
    }

    /// Finish restore: verify exact state; on failure disable capture and
    /// surface a persistent recovery action (failedRestore).
    public mutating func finishRestore(verifiedExact: Bool) {
        guard record.status == .pendingRestore else { return }
        if verifiedExact {
            record.status = .restored
            captureDisabled = false
        } else {
            record.status = .failedRestore
            captureDisabled = true
        }
    }

    /// Crash recovery on next launch. A completed transaction (restored /
    /// failedRestore) must NOT be mistaken for an active override. In-flight
    /// statuses resolve deterministically:
    ///   - pendingApply  -> mutation uncertain -> pendingRestore (must verify)
    ///   - applied       -> active override -> pendingRestore (must restore)
    ///   - pendingRestore-> still must restore -> pendingRestore
    public mutating func recoverAfterCrash() -> FnPreferenceStatus {
        switch record.status {
        case .idle, .restored, .failedRestore:
            return record.status
        case .pendingApply, .applied, .pendingRestore:
            record.status = .pendingRestore
            return .pendingRestore
        }
    }
}

/// Decision policy for the override (JOE-2286 "Production default path
/// never touches the preference").
public enum FnOverridePolicy: Sendable {
    public static func shouldOverride(
        experimentalOptIn: Bool,
        configuredSpecialKeyIsFn: Bool,
        tapPrepared: Bool
    ) -> Bool {
        experimentalOptIn && configuredSpecialKeyIsFn && tapPrepared
    }

    public static func shouldRestoreImmediately(
        configuredSpecialKeyIsFn: Bool,
        accessibilityTrusted: Bool
    ) -> Bool {
        // Changing away from Fn OR losing permission restores immediately.
        !configuredSpecialKeyIsFn || !accessibilityTrusted
    }
}
