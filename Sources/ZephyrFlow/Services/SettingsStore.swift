import Foundation
import SwiftUI
import Combine
import ZephyrFlowCore

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            save()
            ZFLog.debugEnabled = settings.debugLogging
        }
    }

    private let defaultsKey = "zephyrflow.settings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else if let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let migrated = Self.migrate(data) {
            self.settings = migrated
        } else {
            self.settings = .default
        }
        ZFLog.debugEnabled = settings.debugLogging
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
        // Drop legacy no-op key if present
        obj.removeValue(forKey: "playSounds")
        guard let fixed = try? JSONSerialization.data(withJSONObject: obj),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: fixed) else {
            return nil
        }
        return decoded
    }

    private func save() {
        guard let data = try? encoder.encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    func resetToDefaults() {
        let onboarding = settings.hasCompletedOnboarding
        settings = .default
        settings.hasCompletedOnboarding = onboarding
    }
}
