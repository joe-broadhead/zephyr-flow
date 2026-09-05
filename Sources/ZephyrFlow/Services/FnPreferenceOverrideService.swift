import Foundation
import ZephyrFlowCore

/// Narrow injected boundary for the one Fn preference and its journal. No
/// construction-time writes, event taps, permission prompts or unrelated reads.
@MainActor
struct FnPreferenceStorage {
    let readRecord: () throws -> Data?
    let writeRecord: (Data) throws -> Void
    let hasLegacyMarker: () -> Bool
    let readPreference: () throws -> Any?
    let writePreference: (Any?) throws -> Void

    private static let recordKey = "zephyrflow.fnOverride.record.v1"  // retains old records for fail-closed migration
    private enum Failure: Error { case synchronization, malformedJournal }
    static let standard = FnPreferenceStorage(
        readRecord: {
            let defaults = UserDefaults.standard
            guard defaults.synchronize() else { throw Failure.synchronization }
            guard let value = defaults.object(forKey: recordKey) else { return nil }
            guard let data = value as? Data else { throw Failure.malformedJournal }
            return data
        },
        writeRecord: { data in
            let defaults = UserDefaults.standard
            defaults.set(data, forKey: recordKey)
            guard defaults.synchronize(), defaults.data(forKey: recordKey) == data else {
                throw Failure.synchronization
            }
        },
        hasLegacyMarker: {
            UserDefaults.standard.bool(forKey: "zephyrflow.fnOverride.active")
        },
        readPreference: {
            let domain = "com.apple.HIToolbox" as CFString
            guard CFPreferencesAppSynchronize(domain) else { throw Failure.synchronization }
            return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain)
        },
        writePreference: { value in
            let domain = "com.apple.HIToolbox" as CFString
            CFPreferencesSetAppValue("AppleFnUsageType" as CFString, value.map { $0 as CFPropertyList }, domain)
            guard CFPreferencesAppSynchronize(domain) else { throw Failure.synchronization }
        })
}

/// Journal-before-mutation and exact read-back, including the uncertain
/// pendingApply crash window. UserDefaults/CFPreferences acknowledgment is not
/// an fsync/cross-process CAS guarantee. Live crash/device testing is separate.
@MainActor
final class FnPreferenceOverrideService {
    static let shared = FnPreferenceOverrideService()
    private let storage: FnPreferenceStorage
    private var inspected = false
    private(set) var record: FnPreferenceRecord?
    private(set) var recoveryRequired = false
    private(set) var suppressedForLaunch = false
    private(set) var lastError: String?

    init(storage: FnPreferenceStorage? = nil) { self.storage = storage ?? .standard }

    @discardableResult
    func recoverPriorLaunch() -> Bool {
        guard !inspected else { return settled }
        inspected = true
        do {
            guard let data = try storage.readRecord() else {
                // The old marker does not preserve arbitrary original types.
                // Do not erase it or fabricate an "absent" original value.
                if storage.hasLegacyMarker() { return fail() }
                return true
            }
            guard data.count <= FnPreferenceSnapshotCodec.maximumBytes * 2 else { return fail() }
            let saved = try JSONDecoder().decode(FnPreferenceRecord.self, from: data)
            guard (1...FnPreferenceTransaction.recordVersion).contains(saved.version) else { return fail() }
            record = saved
            switch saved.status {
            case .idle, .restored: return true
            case .failedRestore: return fail()  // only an explicit recovery action retries
            case .pendingApply, .applied, .pendingRestore:
                suppressedForLaunch = true
                return restore(explicitRetry: false)
            }
        } catch { return fail() }
    }

    @discardableResult
    func apply(experimentalOptIn: Bool, isFn: Bool, tapPrepared: Bool) -> Bool {
        guard
            FnOverridePolicy.shouldOverride(
                experimentalOptIn: experimentalOptIn,
                configuredSpecialKeyIsFn: isFn, tapPrepared: tapPrepared)
        else { return false }
        _ = recoverPriorLaunch()
        guard !recoveryRequired, !suppressedForLaunch else { return false }
        if record?.status == .applied { return true }
        do {
            let snapshot = try FnPreferenceSnapshotCodec.capture(storage.readPreference())
            var transaction = FnPreferenceTransaction(snapshot: snapshot)
            guard transaction.beginApply() else { return false }
            // A failed journal acknowledgment cannot authorize any mutation.
            record = transaction.record
            try persist(transaction.record)
            do {
                let zero = NSNumber(value: 0)
                try storage.writePreference(zero)
                guard
                    try FnPreferenceSnapshotCodec.matches(
                        storage.readPreference(),
                        snapshot: FnPreferenceSnapshotCodec.capture(zero))
                else { throw ApplyFailure.unverified }
                transaction.markApplied(mutationSucceeded: true)
                try persist(transaction.record)
                record = transaction.record
                lastError = nil
                return true
            } catch {
                // Either the preference or applied-journal acknowledgment may
                // have failed after mutation. Restore, never assume idle.
                suppressedForLaunch = true
                _ = restore(explicitRetry: true)
                return false
            }
        } catch { return fail() }
    }

    @discardableResult
    func restore(explicitRetry: Bool) -> Bool {
        if !inspected { _ = recoverPriorLaunch() }
        if explicitRetry { suppressedForLaunch = true }
        guard let saved = record else { return !recoveryRequired }
        if saved.status == .idle || saved.status == .restored { return !recoveryRequired }
        guard saved.status != .failedRestore || explicitRetry else { return false }
        do {
            let original = try FnPreferenceSnapshotCodec.materialize(saved.snapshot)
            let current = try storage.readPreference()
            let alreadyRestored = try FnPreferenceSnapshotCodec.matches(current, snapshot: saved.snapshot)
            let ownedValue = try FnPreferenceSnapshotCodec.matches(
                current,
                snapshot: FnPreferenceSnapshotCodec.capture(NSNumber(value: 0)))
            // Preserve an unrelated later value rather than pretending we own
            // the preference forever. CFPreferences has no conditional write.
            guard alreadyRestored || ownedValue else { return fail() }
            var transaction = FnPreferenceTransaction(record: saved)
            guard transaction.beginRestore() else { return fail() }
            try persist(transaction.record)
            record = transaction.record
            if !alreadyRestored { try storage.writePreference(original) }
            let verified = try FnPreferenceSnapshotCodec.matches(storage.readPreference(), snapshot: saved.snapshot)
            transaction.finishRestore(verifiedExact: verified)
            try persist(transaction.record)
            record = transaction.record
            if !verified { return fail() }
            recoveryRequired = false
            lastError = nil
            return true
        } catch { return fail() }
    }

    var settled: Bool { !recoveryRequired && record?.isActiveOverride != true }

    private enum ApplyFailure: Error { case unverified }
    private func persist(_ value: FnPreferenceRecord) throws {
        try storage.writeRecord(JSONEncoder().encode(value))
    }
    private func fail() -> Bool {
        recoveryRequired = true
        suppressedForLaunch = true
        lastError = AppStrings.key("hotkey.fnRecovery.failed")
        // Keep the original snapshot/status available even when the journal
        // cannot be updated. Never discard/replace it with the current value.
        if var saved = record, saved.status != .idle, saved.status != .restored {
            saved.status = .failedRestore
            record = saved
            try? persist(saved)
        }
        return false
    }
}
