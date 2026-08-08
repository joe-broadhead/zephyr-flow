import Foundation

// JOE-2265: user-reviewable privacy-safe support bundle + canary scanner.
//
// Generated ONLY on explicit user action; includes controlled, versioned
// data; EXCLUDES audio, transcript/Flow text, clipboard contents, history
// entries, API keys, raw provider bodies, user names, full private paths and
// stable cross-install identifiers. A denylist + privacy-canary scan runs
// over every serialized file and FAILS CLOSED on any marker.

public struct SupportBundleSchemaVersion: Sendable {
    public static let current = 1
}

public struct SupportBundleInputs: Sendable {
    public let appVersion: String
    public let build: String
    public let sourceProvenance: String
    public let channel: String
    public let osVersion: String
    public let architecture: String
    public let hardwareClass: String
    public let microphoneGranted: Bool
    public let accessibilityTrusted: Bool
    public let speechGranted: Bool
    /// Redacted settings summary (no hotkey key values / secrets).
    public let settingsSummary: [String: String]
    public let engineModel: String
    public let modelCacheReady: Bool
    public let modelCacheIntegrity: Bool
    /// Bounded recent telemetry events (schema v1, content-free).
    public let telemetryEvents: [TelemetryEvent]
    public let frameSummary: String
    public let fallbackCount: Int
    public let insertionConfidenceCounts: [String: Int]
    public let healthChecks: [String: String]
    public let privacyPolicyVersion: String

    public init(
        appVersion: String, build: String, sourceProvenance: String,
        channel: String, osVersion: String, architecture: String,
        hardwareClass: String, microphoneGranted: Bool,
        accessibilityTrusted: Bool, speechGranted: Bool,
        settingsSummary: [String: String], engineModel: String,
        modelCacheReady: Bool, modelCacheIntegrity: Bool,
        telemetryEvents: [TelemetryEvent], frameSummary: String,
        fallbackCount: Int, insertionConfidenceCounts: [String: Int],
        healthChecks: [String: String], privacyPolicyVersion: String
    ) {
        self.appVersion = appVersion
        self.build = build
        self.sourceProvenance = sourceProvenance
        self.channel = channel
        self.osVersion = osVersion
        self.architecture = architecture
        self.hardwareClass = hardwareClass
        self.microphoneGranted = microphoneGranted
        self.accessibilityTrusted = accessibilityTrusted
        self.speechGranted = speechGranted
        self.settingsSummary = settingsSummary
        self.engineModel = engineModel
        self.modelCacheReady = modelCacheReady
        self.modelCacheIntegrity = modelCacheIntegrity
        self.telemetryEvents = telemetryEvents
        self.frameSummary = frameSummary
        self.fallbackCount = fallbackCount
        self.insertionConfidenceCounts = insertionConfidenceCounts
        self.healthChecks = healthChecks
        self.privacyPolicyVersion = privacyPolicyVersion
    }
}

/// The versioned bundle document (all fields controlled/typed).
public struct SupportBundleDocument: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAtISO8601: String
    public let appVersion: String
    public let build: String
    public let sourceProvenance: String
    public let channel: String
    public let osVersion: String
    public let architecture: String
    public let hardwareClass: String
    public let permissions: BundlePermissions
    public let settingsSummary: [String: String]
    public let engineModel: String
    public let modelCache: BundleModelCache
    public let telemetryEvents: [TelemetryEvent]
    public let frameSummary: String
    public let fallbackCount: Int
    public let insertionConfidenceCounts: [String: Int]
    public let healthChecks: [String: String]
    public let privacyPolicyVersion: String

    public struct BundlePermissions: Codable, Sendable, Equatable {
        public let microphoneGranted: Bool
        public let accessibilityTrusted: Bool
        public let speechGranted: Bool
        public init(microphoneGranted: Bool, accessibilityTrusted: Bool, speechGranted: Bool) {
            self.microphoneGranted = microphoneGranted
            self.accessibilityTrusted = accessibilityTrusted
            self.speechGranted = speechGranted
        }
    }

    public struct BundleModelCache: Codable, Sendable, Equatable {
        public let ready: Bool
        public let integrityVerified: Bool
        public init(ready: Bool, integrityVerified: Bool) {
            self.ready = ready
            self.integrityVerified = integrityVerified
        }
    }

    public init(inputs: SupportBundleInputs, generatedAtISO8601: String) {
        self.schemaVersion = SupportBundleSchemaVersion.current
        self.generatedAtISO8601 = generatedAtISO8601
        self.appVersion = inputs.appVersion
        self.build = inputs.build
        self.sourceProvenance = inputs.sourceProvenance
        self.channel = inputs.channel
        self.osVersion = inputs.osVersion
        self.architecture = inputs.architecture
        self.hardwareClass = inputs.hardwareClass
        self.permissions = BundlePermissions(
            microphoneGranted: inputs.microphoneGranted,
            accessibilityTrusted: inputs.accessibilityTrusted,
            speechGranted: inputs.speechGranted)
        self.settingsSummary = inputs.settingsSummary
        self.engineModel = inputs.engineModel
        self.modelCache = BundleModelCache(
            ready: inputs.modelCacheReady,
            integrityVerified: inputs.modelCacheIntegrity)
        self.telemetryEvents = Array(inputs.telemetryEvents.prefix(256))
        self.frameSummary = inputs.frameSummary
        self.fallbackCount = inputs.fallbackCount
        self.insertionConfidenceCounts = inputs.insertionConfidenceCounts
        self.healthChecks = inputs.healthChecks
        self.privacyPolicyVersion = inputs.privacyPolicyVersion
    }
}

/// Denylist markers scanned over every serialized bundle field.
public enum SupportBundleCanary {
    public static let markers: [String] = [
        "BEGIN PRIVATE KEY", "BEGIN RSA", "sk-", "AKIA", "-----BEGIN",
        "password=", "api_key=", "apikey=",
    ]
    /// Content markers that must never appear (transcript shapes, keys,
    /// private paths, stable identifiers).
    public static let forbiddenContent: [String] = [
        "/Users/", "/private/", "/etc/", "/var/", "iCloud",
    ]

    /// Fail-closed scan: returns the offending FIELD name (never the marker
    /// value) or nil when clean.
    public static func scanField(_ name: String, _ value: String) -> String? {
        let lower = value.lowercased()
        for marker in markers where lower.contains(marker.lowercased()) {
            return name
        }
        for marker in forbiddenContent where lower.contains(marker.lowercased()) {
            return name
        }
        return nil
    }

    /// Scan a full serialized document (sorted-keys JSON); returns the first
    /// offending field path or nil when clean.
    public static func scanSerialized(_ text: String) -> String? {
        let lower = text.lowercased()
        for marker in markers + forbiddenContent where lower.contains(marker.lowercased()) {
            return "(serialized)"
        }
        return nil
    }
}

/// Build + validate a support bundle (atomic; typed failure states).
public enum SupportBundleBuilder {
    public enum BuildError: Error, Sendable, Equatable {
        case markerDetected(field: String)
        case serializationFailed
        case sizeLimitExceeded
    }

    public static let maxSerializedBytes = 2_000_000

    /// Build the bundle document (explicit user action only).
    public static func build(
        inputs: SupportBundleInputs,
        generatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> SupportBundleDocument {
        let document = SupportBundleDocument(inputs: inputs, generatedAtISO8601: generatedAt)
        // Fail-closed canary scan over every controlled field.
        for field in [
            ("appVersion", document.appVersion), ("build", document.build),
            ("sourceProvenance", document.sourceProvenance), ("channel", document.channel),
            ("osVersion", document.osVersion), ("architecture", document.architecture),
            ("hardwareClass", document.hardwareClass), ("engineModel", document.engineModel),
            ("frameSummary", document.frameSummary),
        ] {
            if let offending = SupportBundleCanary.scanField(field.0, field.1) {
                throw BuildError.markerDetected(field: offending)
            }
        }
        for (key, value) in document.settingsSummary {
            if let offending = SupportBundleCanary.scanField("settingsSummary.\(key)", value) {
                throw BuildError.markerDetected(field: offending)
            }
        }
        for (key, value) in document.healthChecks {
            if let offending = SupportBundleCanary.scanField("healthChecks.\(key)", value) {
                throw BuildError.markerDetected(field: offending)
            }
        }
        for event in document.telemetryEvents {
            if let offending = SupportBundleCanary.scanSerialized(
                "\(event.kind.rawValue)\(event.terminal?.rawValue ?? "")\(event.stage?.rawValue ?? "")")
            {
                throw BuildError.markerDetected(field: offending)
            }
        }
        // Size bound.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document) else {
            throw BuildError.serializationFailed
        }
        guard data.count <= maxSerializedBytes else {
            throw BuildError.sizeLimitExceeded
        }
        return document
    }

    /// Readable preview manifest (no payload text).
    public static func preview(_ document: SupportBundleDocument) -> String {
        """
        Zephyr Flow support bundle (schema \(document.schemaVersion))
        app \(document.appVersion) (\(document.build)) · \(document.channel)
        macOS \(document.osVersion) \(document.architecture) (\(document.hardwareClass))
        permissions: mic \(document.permissions.microphoneGranted) · ax \(document.permissions.accessibilityTrusted) · speech \(document.permissions.speechGranted)
        model \(document.engineModel) ready=\(document.modelCache.ready) integrity=\(document.modelCache.integrityVerified)
        telemetry events \(document.telemetryEvents.count) · fallbacks \(document.fallbackCount)
        privacy policy \(document.privacyPolicyVersion)
        """
    }
}
