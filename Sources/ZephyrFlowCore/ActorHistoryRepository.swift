import Foundation

// JOE-2261: actor-isolated, opt-in, bounded history repository.
// Async I/O off the MainActor; atomic durable writes; restrictive
// permissions; schema versioning; corruption quarantine; recoverable
// migration from the legacy v1 JSON; failure-aware clear/delete; retention
// by age/bytes/entries.

public enum HistoryRepositoryError: Error, Sendable, Equatable {
    case diskFull
    case permissionDenied
    case corruptionDetected
    case migrationFailed(String)
    case ioFailed
}

/// Actor history repository (implements HistoryRepository + UI operations).
public actor ActorHistoryRepository: HistoryRepository {
    public static let shared = ActorHistoryRepository()

    private let fileURL: URL
    private let fileSystem: any HistoryFileSystem
    private let retention: HistoryRetentionPolicy
    private var document: HistoryDocument
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    // JOE-2262: at-rest encryption (defense-in-depth, opt-in history).
    private let cipher: HistoryCipherEngine
    private var keyProvider: @Sendable () -> HistoryCryptoKey?
    /// Set when the key is missing/inaccessible: no plaintext is exposed and
    /// recovery behavior is explicit (content stays sealed on disk).
    public private(set) var recoveryState: String?
    private var usingEncryption = false

    public init(
        fileURL: URL? = nil,
        fileSystem: any HistoryFileSystem = RealHistoryFileSystem(),
        retention: HistoryRetentionPolicy = HistoryRetentionPolicy(),
        cipher: HistoryCipherEngine = .shared,
        keyProvider: @escaping @Sendable () -> HistoryCryptoKey? = { nil }
    ) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("ZephyrFlow", isDirectory: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("history.json")
        self.fileSystem = fileSystem
        self.retention = retention
        self.cipher = cipher
        self.keyProvider = keyProvider
        self.document = HistoryDocument(entries: [])
        self.encoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
    }

    /// JOE-2262: configure the at-rest encryption key provider (production
    /// uses the non-synchronizing Keychain item; tests inject fakes).
    public func configureEncryption(keyProvider: @escaping @Sendable () -> HistoryCryptoKey?) {
        self.keyProvider = keyProvider
    }

    /// Load + migrate on first use (recoverable from corruption).
    public func load() async throws {
        try fileSystem.createDirectory(fileURL.deletingLastPathComponent())
        try fileSystem.setPermissions(fileURL.deletingLastPathComponent(), mode: 0o700)
        guard fileSystem.fileExists(fileURL) else {
            document = HistoryDocument(entries: [])
            return
        }
        do {
            let data = try fileSystem.readData(fileURL)
            // Encrypted document: decrypt with the current key; a missing or
            // wrong key NEVER yields partial plaintext — explicit recovery.
            if let encrypted = try? decoder.decode(EncryptedHistoryDocument.self, from: data) {
                usingEncryption = true
                if let key = keyProvider(),
                    let decrypted = HistoryEncryptionMigration.decrypt(
                        document: encrypted, key: key, engine: cipher)
                {
                    document = decrypted
                    recoveryState = nil
                } else {
                    document = HistoryDocument(entries: [])
                    recoveryState =
                        "history key missing or invalid — sealed content retained on disk, no plaintext exposed"
                }
            } else {
                document = try decode(data)
            }
            document.entries = HistoryStoragePolicy.trimmed(
                document.entries,
                policy: retention,
                now: Date())
        } catch {
            // Corruption: quarantine the file and start clean (recoverable).
            let quarantine = fileURL.appendingPathExtension("quarantined")
            try? fileSystem.move(fileURL, to: quarantine)
            document = HistoryDocument(entries: [])
            throw HistoryRepositoryError.corruptionDetected
        }
    }

    private func decode(_ data: Data) throws -> HistoryDocument {
        // v1 legacy: plain [HistoryEntry] array.
        if let v1 = try? decoder.decode([LegacyHistoryEntryV1].self, from: data) {
            let migrated = v1.map { entry in
                HistoryStorageEntry(
                    timestamp: entry.timestamp, text: entry.finalText,
                    duration: entry.duration, modelUsed: entry.modelUsed,
                    sensitivityClass: "normal")
            }
            return HistoryDocument(
                schemaVersion: HistoryDocument.currentSchemaVersion,
                entries: migrated)
        }
        return try decoder.decode(HistoryDocument.self, from: data)
    }

    // MARK: HistoryRepository

    public func add(_ entry: HistoryEntry) async {
        let storage = HistoryStorageEntry(
            timestamp: entry.timestamp,
            text: entry.finalText,
            duration: entry.duration,
            modelUsed: entry.modelUsed,
            sensitivityClass: "normal")
        await add(storage)
    }

    /// Policy-gated add: only normal-sensitivity, outcome-permitted writes.
    public func add(_ entry: HistoryStorageEntry) async {
        document.entries.insert(entry, at: 0)
        document.entries = HistoryStoragePolicy.trimmed(
            document.entries,
            policy: retention,
            now: Date())
        await persist()
    }

    public func entries() async -> [HistoryStorageEntry] { document.entries }

    public func clear() async throws {
        document = HistoryDocument(entries: [])
        try await persistOrThrow()
    }

    public func delete(_ id: UUID) async throws {
        document.entries.removeAll { $0.id == id }
        try await persistOrThrow()
    }

    /// True when a write would be allowed by policy (used by callers to skip
    /// non-normal sessions without touching the repository).
    public func allowsWrite(sensitivity: SessionSensitivity, outcome: InsertionOutcome?) -> Bool {
        HistoryStoragePolicy.allowsWrite(sensitivity: sensitivity, outcome: outcome)
    }

    // MARK: Persistence

    private func persist() async {
        try? await persistOrThrow()
    }

    private func persistOrThrow() async throws {
        do {
            let data: Data
            if let key = keyProvider() {
                usingEncryption = true
                let encrypted = try HistoryEncryptionMigration.encrypt(
                    document: document, key: key, engine: cipher)
                data = try encoder.encode(encrypted)
            } else {
                data = try encoder.encode(document)
            }
            try fileSystem.writeAtomic(data: data, to: fileURL)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
                error.code == NSFileWriteOutOfSpaceError
            {
                throw HistoryRepositoryError.diskFull
            }
            if error.domain == NSCocoaErrorDomain,
                error.code == NSFileWriteNoPermissionError
            {
                throw HistoryRepositoryError.permissionDenied
            }
            throw HistoryRepositoryError.ioFailed
        }
    }
}

/// v1 legacy shape (raw + transformed both stored — migrated to single text).
private struct LegacyHistoryEntryV1: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let originalText: String
    public let finalText: String
    public let duration: TimeInterval
    public let modelUsed: String
}
