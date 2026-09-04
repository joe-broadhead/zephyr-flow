import Foundation

// JOE-2261: opt-in bounded actor history — policy + storage contract.
//
// History is an explicit, bounded, failure-aware user feature: default OFF
// for new installs; only sessions allowed by sensitivity AND outcome policy
// are stored; minimum fields only (single text, no raw+transformed
// duplication); retention by age/bytes/entries; actor-isolated async I/O.

/// Retention bounds for stored history.
public struct HistoryRetentionPolicy: Sendable, Equatable {
    public let maxAgeSeconds: TimeInterval
    public let maxTotalBytes: Int
    public let maxEntries: Int

    public init(
        maxAgeSeconds: TimeInterval = 30 * 24 * 3600,
        maxTotalBytes: Int = 4_000_000,
        maxEntries: Int = 500
    ) {
        self.maxAgeSeconds = maxAgeSeconds
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
    }
}

/// Data-minimized storage entry: ONE text field (the user-facing transcript),
/// no raw+transformed duplication; sensitivity class retained for UI.
public struct HistoryStorageEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let text: String
    public let duration: TimeInterval
    public let modelUsed: String
    public let sensitivityClass: String

    public init(
        id: UUID = UUID(), timestamp: Date, text: String,
        duration: TimeInterval, modelUsed: String,
        sensitivityClass: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.duration = duration
        self.modelUsed = modelUsed
        self.sensitivityClass = sensitivityClass
    }
}

/// Versioned on-disk history document.
public struct HistoryDocument: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var entries: [HistoryStorageEntry]

    public init(schemaVersion: Int = 2, entries: [HistoryStorageEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public static let currentSchemaVersion = 2
}

/// Central history-write gate (JOE-2259/2269/2261): only normal-sensitivity
/// sessions whose outcome permits history retention are stored.
public enum HistoryStoragePolicy {
    /// New-install default: history OFF (opt-in). Existing explicit choices
    /// are preserved by versioned migration.
    public static let defaultEnabled = false

    public static func allowsWrite(
        sensitivity: SessionSensitivity,
        outcome: InsertionOutcome?
    ) -> Bool {
        guard sensitivity.allowsAutomaticSideEffects else { return false }
        if let outcome {
            return outcome.permitsHistoryRetention
        }
        // No outcome yet (pre-insertion): deny (fail closed).
        return false
    }

    /// Applies retention: age + byte + entry bounds.
    public static func trimmed(
        _ entries: [HistoryStorageEntry],
        policy: HistoryRetentionPolicy,
        now: Date
    ) -> [HistoryStorageEntry] {
        var list = entries.filter { now.timeIntervalSince($0.timestamp) <= policy.maxAgeSeconds }
        if list.count > policy.maxEntries {
            list = Array(list.prefix(policy.maxEntries))
        }
        var total = 0
        var result: [HistoryStorageEntry] = []
        for entry in list {
            let bytes = entry.text.utf8.count + 64
            if total + bytes > policy.maxTotalBytes { break }
            total += bytes
            result.append(entry)
        }
        return result
    }
}

/// Injectable filesystem boundary for the history repository (tests inject
/// failing/corrupting adapters).
public protocol HistoryFileSystem: Sendable {
    func fileExists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func readData(_ url: URL) throws -> Data
    func writeAtomic(data: Data, to url: URL) throws
    func move(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    func setPermissions(_ url: URL, mode: Int) throws
}

/// Real filesystem adapter (restrictive permissions; atomic rename).
public struct RealHistoryFileSystem: HistoryFileSystem {
    public init() {}
    public func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func readData(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func writeAtomic(data: Data, to url: URL) throws {
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }
    public func move(_ from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func setPermissions(_ url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
