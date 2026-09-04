import Foundation

// JOE-2286: exact + transactional Fn/Globe preference override.
//
// The production default path NEVER touches the system preference. The
// optional single-Fn override only begins after explicit experimental
// opt-in AND successful hotkey/tap preparation; it snapshots the EXACT
// prior state (presence, value, CF type, suite/domain), persists a
// versioned transaction record BEFORE mutation, atomically marks
// apply/restore status, restores exactly the original state (never an
// unconditional key removal after a value was present), verifies by
// read-back, and on restore failure disables Fn capture + surfaces a
// persistent recovery action without re-applying automatically. Crash
// recovery on next launch is idempotent and never mistakes a COMPLETED
// transaction for an ACTIVE override.

public enum FnPreferenceStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case idle  // no override ever started
    case pendingApply  // record written, mutation not yet applied
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

    public init(
        keyPresent: Bool, value: Int64?, cfTypeTag: String?,
        suiteName: String = "com.apple.HIToolbox",
        keyName: String = "AppleFnUsageType"
    ) {
        self.keyPresent = keyPresent
        self.value = value
        self.cfTypeTag = cfTypeTag
        self.suiteName = suiteName
        self.keyName = keyName
    }

    public static let none = FnPreferenceSnapshot(keyPresent: false, value: nil, cfTypeTag: nil)
}

public struct FnPreferenceRecord: Codable, Equatable, Sendable {
    /// Monotonic version; never reused. A higher version always wins.
    public var version: Int
    public var status: FnPreferenceStatus
    public var snapshot: FnPreferenceSnapshot

    public init(version: Int, status: FnPreferenceStatus, snapshot: FnPreferenceSnapshot) {
        self.version = version
        self.status = status
        self.snapshot = snapshot
    }

    /// A COMPLETED transaction (restored/failedRestore) is never an active
    /// override. Only `applied` (or in-flight apply/restore) triggers
    /// recovery action on next launch.
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
    public static let recordVersion = 1
    public var record: FnPreferenceRecord
    public private(set) var captureDisabled: Bool

    public init(record: FnPreferenceRecord) {
        self.record = record
        self.captureDisabled = false
    }

    public init(snapshot: FnPreferenceSnapshot, version: Int = 1) {
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

    /// Apply the mutation; atomically mark applied. Fault-injectable: the
    /// caller decides whether the underlying mutation actually happened.
    public mutating func markApplied(mutationSucceeded: Bool) {
        if mutationSucceeded {
            record.status = .applied
        } else {
            // Mutation never happened: restore the record to idle.
            record.status = .idle
        }
    }

    /// Begin restore (never re-applies automatically).
    public mutating func beginRestore() -> Bool {
        guard record.status == .applied || record.status == .pendingApply else {
            return false
        }
        record.status = .pendingRestore
        return true
    }

    /// Finish restore: verify exact state; on failure disable capture and
    /// surface a persistent recovery action (failedRestore).
    public mutating func finishRestore(verifiedExact: Bool) {
        if verifiedExact {
            record.status = .restored
        } else {
            record.status = .failedRestore
            captureDisabled = true
        }
    }

    /// Crash recovery on next launch. A completed transaction (restored /
    /// failedRestore) must NOT be mistaken for an active override. In-flight
    /// statuses resolve deterministically:
    ///   - pendingApply  -> mutation never confirmed -> idle (nothing done)
    ///   - applied       -> active override -> pendingRestore (must restore)
    ///   - pendingRestore-> still must restore -> pendingRestore
    public mutating func recoverAfterCrash() -> FnPreferenceStatus {
        switch record.status {
        case .idle, .restored, .failedRestore:
            return record.status
        case .pendingApply:
            record.status = .idle
            return .idle
        case .applied, .pendingRestore:
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
