import Combine
import Foundation
import SwiftUI
import ZephyrFlowCore

/// Injectable acknowledgment boundary. UserDefaults synchronization/read-back
/// is not an fsync or a cross-process transaction; restart/device durability
/// still needs qualification. Tests use in-memory closures only.
@MainActor
struct SettingsPersistence {
    let read: () -> Data?
    let write: (Data) -> Bool
    let quarantine: (Data, String) -> Void

    static let standard = SettingsPersistence(
        read: { UserDefaults.standard.data(forKey: "zephyrflow.settings") },
        write: { data in
            let defaults = UserDefaults.standard
            let key = "zephyrflow.settings"
            let previous = defaults.data(forKey: key)
            defaults.set(data, forKey: key)
            guard defaults.synchronize(), defaults.data(forKey: key) == data else {
                // Best effort to restore our previous preference. Failure is
                // surfaced, never relabeled as a confirmed settings change.
                if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
                _ = defaults.synchronize()
                return false
            }
            return true
        }, quarantine: { data, key in UserDefaults.standard.set(data, forKey: key) })
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: AppSettings
    @Published private(set) var persistenceError: String?

    @Published var recoveryState: SettingsRecoveryState = .ok

    private let persistence: SettingsPersistence
    private let quarantinePrefix = "zephyrflow.settings.quarantine"
    private var provenance: [String] = []

    enum SettingsRecoveryState: Equatable {
        case ok
        case recoveredFromCorruption
        case unknownSchema(Int)
    }

    init(persistence: SettingsPersistence? = nil) {
        let persistence = persistence ?? .standard
        self.persistence = persistence
        let data = persistence.read()
        let result = SettingsStorageCoordinator.load(data: data)
        if result.recoveredFromCorruption {
            // Quarantine the ORIGINAL bytes for recovery, then safe baseline.
            if let data {
                persistence.quarantine(data, result.quarantinePath ?? "\(quarantinePrefix).1")
            }
            if let unknown = result.unknownSchemaVersion {
                recoveryState = .unknownSchema(unknown)
            } else {
                recoveryState = .recoveredFromCorruption
            }
            self.settings = result.settings
            ZFLog.info("Settings recovered from corruption — safe baseline active")
        } else {
            recoveryState = .ok
            self.settings = result.settings
        }
        if let from = result.migratedFromVersion {
            provenance = ["v\(from)-migrated"]
        } else {
            provenance = ["v\(SettingsStorageCoordinator.currentSchemaVersion)"]
        }
        ZFLog.debugEnabled = settings.debugLogging
    }

    /// Publish only after the persistence boundary acknowledges the candidate.
    @discardableResult
    func commit() -> Bool {
        persistAndPublish(settings)
    }

    private func persistAndPublish(_ candidate: AppSettings) -> Bool {
        do {
            let data = try SettingsStorageCoordinator.encode(
                settings: candidate,
                provenance: provenance)
            guard persistence.write(data) else { throw CocoaError(.fileWriteUnknown) }
            settings = candidate
            ZFLog.debugEnabled = candidate.debugLogging
            persistenceError = nil
            return true
        } catch {
            persistenceError = AppStrings.key("settings.persistence.failed")
            ZFLog.error("Settings commit failed")
            return false
        }
    }

    /// Forward-compatible decode: fill new keys with defaults when missing.
    private static func migrate(_ data: Data) -> AppSettings? {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let defaults = AppSettings.default
        if obj["allowModelDownloads"] == nil { obj["allowModelDownloads"] = defaults.allowModelDownloads }
        if obj["debugLogging"] == nil { obj["debugLogging"] = defaults.debugLogging }
        if obj["saveHistory"] == nil { obj["saveHistory"] = defaults.saveHistory }
        if obj["flowBackend"] == nil { obj["flowBackend"] = defaults.flowBackend.rawValue }
        if obj["insertionMode"] == nil { obj["insertionMode"] = defaults.insertionMode.rawValue }
        if obj["panelPositionLocked"] == nil { obj["panelPositionLocked"] = defaults.panelPositionLocked }
        if obj["copyOnlyOverrideBundleIDs"] == nil {
            obj["copyOnlyOverrideBundleIDs"] = defaults.copyOnlyOverrideBundleIDs
        }
        // JOE-2254: legacy free-form language string -> validated model.
        if let legacy = obj["language"] as? String, SupportedLanguage(rawValue: legacy) == nil {
            obj["language"] = SupportedLanguage.fromLegacy(legacy).rawValue
        }
        if obj["language"] == nil { obj["language"] = defaults.language.rawValue }
        // Drop legacy no-op key if present
        obj.removeValue(forKey: "playSounds")
        guard let fixed = try? JSONSerialization.data(withJSONObject: obj),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: fixed)
        else {
            return nil
        }
        return decoded
    }

    func save() {
        _ = commit()
    }

    @discardableResult
    func update(_ mutate: (inout AppSettings) -> Void) -> Bool {
        var copy = settings
        mutate(&copy)
        return persistAndPublish(copy)
    }

    @discardableResult
    func resetToDefaults() -> Bool {
        // JOE-2263: transactional reset preserving only documented fields.
        let next = SettingsStorageCoordinator.resetPayload(current: settings)
        return persistAndPublish(next)
    }
}
