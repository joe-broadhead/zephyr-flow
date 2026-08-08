import Foundation
import SwiftUI
import Combine
import ZephyrFlowCore

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            _ = commit()
            ZFLog.debugEnabled = settings.debugLogging
        }
    }

    @Published var recoveryState: SettingsRecoveryState = .ok

    private let defaultsKey = "zephyrflow.settings"
    private let quarantinePrefix = "zephyrflow.settings.quarantine"
    private var provenance: [String] = []

    enum SettingsRecoveryState: Equatable {
        case ok
        case recoveredFromCorruption
        case unknownSchema(Int)
    }

    private init() {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        let result = SettingsStorageCoordinator.load(data: data)
        if result.recoveredFromCorruption {
            // Quarantine the ORIGINAL bytes for recovery, then safe baseline.
            if let data {
                UserDefaults.standard.set(data, forKey: result.quarantinePath ?? "\(quarantinePrefix).1")
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

    /// Atomic commit; returns success so UI never claims a change that was
    /// not durably written.
    @discardableResult
    func commit() -> Bool {
        do {
            let data = try SettingsStorageCoordinator.encode(settings: settings,
                                                             provenance: provenance)
            UserDefaults.standard.set(data, forKey: defaultsKey)
            return true
        } catch {
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
        if obj["copyOnlyOverrideBundleIDs"] == nil { obj["copyOnlyOverrideBundleIDs"] = defaults.copyOnlyOverrideBundleIDs }
        // JOE-2254: legacy free-form language string -> validated model.
        if let legacy = obj["language"] as? String, SupportedLanguage(rawValue: legacy) == nil {
            obj["language"] = SupportedLanguage.fromLegacy(legacy).rawValue
        }
        if obj["language"] == nil { obj["language"] = defaults.language.rawValue }
        // Drop legacy no-op key if present
        obj.removeValue(forKey: "playSounds")
        guard let fixed = try? JSONSerialization.data(withJSONObject: obj),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: fixed) else {
            return nil
        }
        return decoded
    }

    func save() {
        _ = commit()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    func resetToDefaults() {
        // JOE-2263: transactional reset preserving only documented fields.
        let next = SettingsStorageCoordinator.resetPayload(current: settings)
        settings = next
        _ = commit()
    }
}
