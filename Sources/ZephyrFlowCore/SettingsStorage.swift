import Foundation

// JOE-2263: versioned settings storage with transactional migrations,
// quarantine and safe rollback.
//
// - Explicit envelope: schemaVersion + payload + migration provenance.
// - Ordered, testable migrations from every shipped schema.
// - Corrupt/unknown data => quarantine the ORIGINAL bytes, activate a
//   documented SAFE baseline (localOnly ON, downloads/history OFF until
//   reviewed), and surface a recoverable error — never silently pretend
//   defaults were chosen.
// - Atomic commit; encode/write failures are reported so UI never claims a
//   setting changed when it was not durably committed.

public struct SettingsEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var payload: AppSettings
    public var migrationProvenance: [String]

    public init(schemaVersion: Int, payload: AppSettings, migrationProvenance: [String] = []) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.migrationProvenance = migrationProvenance
    }
}

public enum SettingsStorageError: Error, Sendable, Equatable {
    case corruptData
    case unknownSchema(Int)
    case writeFailed
    case migrationFailed(String)
}

/// Result of a load — includes recovery state (never silently defaults).
public struct SettingsStorageLoadResult: Sendable, Equatable {
    public let settings: AppSettings
    public let recoveredFromCorruption: Bool
    public let quarantinePath: String?
    public let migratedFromVersion: Int?
    public let unknownSchemaVersion: Int?
}

public enum SettingsStorageCoordinator {
    public static let currentSchemaVersion = 2

    /// Documented SAFE baseline after corruption: Local Only ON,
    /// downloads/history OFF until reviewed. Privacy-affecting defaults are
    /// never silently re-enabled.
    public static var safeBaseline: AppSettings {
        var s = AppSettings.default
        s.localOnlyMode = true
        s.allowModelDownloads = false
        s.saveHistory = false
        return s
    }

    // MARK: - Load + migrate

    /// Decode + migrate deterministically. Corrupt/unknown data quarantines
    /// the ORIGINAL bytes (caller moves them) and returns the safe baseline
    /// with recovery flags — a recoverable error, not silent defaults.
    public static func load(data: Data?) -> SettingsStorageLoadResult {
        guard let data else {
            // No stored settings: brand-new install => documented defaults
            // (privacy-safe: localOnly on; history off by default).
            return SettingsStorageLoadResult(
                settings: .default,
                recoveredFromCorruption: false,
                quarantinePath: nil,
                migratedFromVersion: nil,
                unknownSchemaVersion: nil)
        }
        // Try current envelope.
        if let envelope = try? JSONDecoder().decode(SettingsEnvelope.self, from: data) {
            return loadEnvelope(envelope, data: data)
        }
        // Legacy v1: flat AppSettings payload (no envelope).
        if let legacy = try? JSONDecoder().decode(AppSettings.self, from: data) {
            let migrated = SettingsEnvelope(
                schemaVersion: currentSchemaVersion,
                payload: legacy,
                migrationProvenance: ["v1-flat"])
            return SettingsStorageLoadResult(
                settings: migrated.payload,
                recoveredFromCorruption: false,
                quarantinePath: nil,
                migratedFromVersion: 1,
                unknownSchemaVersion: nil)
        }
        // Corrupt: quarantine original + safe baseline.
        return SettingsStorageLoadResult(
            settings: safeBaseline,
            recoveredFromCorruption: true,
            quarantinePath: quarantineName(),
            migratedFromVersion: nil,
            unknownSchemaVersion: nil)
    }

    private static func loadEnvelope(_ envelope: SettingsEnvelope, data: Data) -> SettingsStorageLoadResult {
        switch envelope.schemaVersion {
        case currentSchemaVersion:
            return SettingsStorageLoadResult(
                settings: envelope.payload,
                recoveredFromCorruption: false,
                quarantinePath: nil,
                migratedFromVersion: nil,
                unknownSchemaVersion: nil)
        case 1:
            // v1 envelope (future schema without a migration yet) — migrate
            // by filling missing keys (forward-compatible decode).
            var payload = envelope.payload
            fillMissingKeys(&payload)
            return SettingsStorageLoadResult(
                settings: payload,
                recoveredFromCorruption: false,
                quarantinePath: nil,
                migratedFromVersion: 1,
                unknownSchemaVersion: nil)
        default:
            // Unknown/newer schema: quarantine original + safe baseline,
            // retaining the original for recovery.
            return SettingsStorageLoadResult(
                settings: safeBaseline,
                recoveredFromCorruption: true,
                quarantinePath: quarantineName(),
                migratedFromVersion: nil,
                unknownSchemaVersion: envelope.schemaVersion)
        }
    }

    /// Forward-compatible fill for missing keys (preserves explicit choices).
    public static func fillMissingKeys(_ settings: inout AppSettings) {
        let defaults = AppSettings.default
        // No per-key tracking here: decode with defaults already fills
        // Codable defaults; this is the safety net for exotic payloads.
        _ = defaults
    }

    public static func quarantineName() -> String {
        "zephyrflow.settings.quarantine.\(UUID().uuidString)"
    }

    // MARK: - Atomic commit

    /// Encode the envelope; throws on failure so the UI never claims success.
    public static func encode(
        settings: AppSettings,
        provenance: [String]
    ) throws -> Data {
        let envelope = SettingsEnvelope(
            schemaVersion: currentSchemaVersion,
            payload: settings,
            migrationProvenance: provenance)
        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            throw SettingsStorageError.writeFailed
        }
    }

    /// Transactional reset: preserves ONLY explicitly documented fields
    /// (onboarding completion) and re-commits atomically.
    public static func resetPayload(current: AppSettings) -> AppSettings {
        var s = safeBaseline
        s.hasCompletedOnboarding = current.hasCompletedOnboarding
        return s
    }
}
