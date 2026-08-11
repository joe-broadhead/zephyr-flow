import Foundation

/// Round-5 REQ-5: explicit history-storage states. Only actual
/// decode/authentication corruption quarantines; storage I/O failures,
/// missing keys and pending migrations are distinct, observable states so
/// admission can decide based on real encryption readiness.
public enum HistoryStorageState: String, Codable, Sendable, Equatable, CaseIterable {
    case uninitialized
    /// Valid document loaded; encryption active (or empty-and-encrypted).
    case readyEncrypted
    /// Valid document loaded; encryption not configured.
    case readyPlaintext
    /// Plaintext loaded with encryption configured but the migration persist
    /// failed — data is safe (still plaintext), retry on next launch.
    case plaintextMigrationPending
    /// Sealed data exists but the key is unavailable — never expose plaintext,
    /// refuse writes.
    case sealedKeyUnavailable
    /// The history file could not be READ (permission/I/O) — NOT corruption.
    case storageReadFailure
    /// Genuine corruption: the file was quarantined and a clean store started.
    case corruptQuarantined
    /// History feature disabled by the user — dictation proceeds, no writes.
    case historyDisabled
}

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
    /// Last persistence error (surfaced to UI; review R4.1). Nil when the
    /// last write succeeded. Kept as a string (user-safe, no payload).
    public private(set) var lastWriteError: String?
    /// Review R7: explicit initialization state. Writes are fail-closed until
    /// the repository is initialized (key configured + load completed). Once
    /// encryption is configured or sealed data exists, a missing key NEVER
    /// falls back to plaintext.
    public private(set) var isInitialized = false
    /// Round-5 REQ-5: explicit storage state (see HistoryStorageState).
    public private(set) var storageState: HistoryStorageState = .uninitialized
    /// Review R7: true once encryption has been configured (Keychain key).
    public private(set) var encryptionConfigured = false
    /// Review R7: true when sealed (encrypted) data exists on disk and the key
    /// is unavailable — writes must be refused (never overwrite with plaintext).
    public private(set) var sealedDataUnreadable = false

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
        self.encryptionConfigured = true
    }

    /// Round-5 REQ-5: mark history as user-disabled (dictation proceeds, no
    /// writes). The controller calls this when the user has history OFF.
    public func markHistoryDisabled() {
        storageState = .historyDisabled
    }

    /// Load + migrate on first use (recoverable from corruption).
    public func load() async throws {
        try fileSystem.createDirectory(fileURL.deletingLastPathComponent())
        try fileSystem.setPermissions(fileURL.deletingLastPathComponent(), mode: 0o700)
        guard fileSystem.fileExists(fileURL) else {
            document = HistoryDocument(entries: [])
            // Review B8: a fresh install (no file) is still INITIALIZED (empty
            // but writable) — previously this returned without setting the flag.
            // Round-5 REQ-5: record whether the fresh store is encrypted-ready.
            isInitialized = true
            storageState =
                (encryptionConfigured && keyProvider() != nil)
                ? .readyEncrypted
                : (encryptionConfigured ? .sealedKeyUnavailable : .readyPlaintext)
            return
        }
        do {
            let data: Data
            do {
                data = try fileSystem.readData(fileURL)
            } catch {
                // Round-5 REQ-5: a READ failure (permission/I/O) is NOT
                // corruption — never quarantine a valid file because it could
                // not be read. Surface the distinct state.
                storageState = .storageReadFailure
                recoveryState = "history file could not be read: \(String(describing: error))"
                throw HistoryRepositoryError.ioFailed
            }
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
                    sealedDataUnreadable = false
                    storageState = .readyEncrypted
                } else {
                    document = HistoryDocument(entries: [])
                    recoveryState =
                        "history key missing or invalid — sealed content retained on disk, no plaintext exposed"
                    // Review R7: sealed data exists but the key is unavailable —
                    // writes MUST be refused, never overwrite with plaintext.
                    // Round-5 REQ-5: distinct state (never empty-in-memory
                    // admission; the controller surfaces it).
                    sealedDataUnreadable = true
                    storageState = .sealedKeyUnavailable
                }
            } else {
                document = try decode(data)
                // Review B5v2: the repository is logically initialized once a
                // valid document is decoded — set the flag BEFORE the
                // migration persist so the init guard in persistOrThrow passes
                // (otherwise every configured plaintext migration failed and
                // was quarantined as corruption).
                isInitialized = true
                // Round-5 REQ-5: plaintext loaded — state reflects whether
                // encryption is active yet.
                storageState =
                    (encryptionConfigured && keyProvider() != nil)
                    ? .readyEncrypted
                    : (encryptionConfigured ? .sealedKeyUnavailable : .readyPlaintext)
                // Review B8: a plaintext legacy document loaded while
                // encryption is configured is immediately re-encrypted so
                // existing history does not remain plaintext indefinitely.
                if encryptionConfigured, keyProvider() != nil {
                    do {
                        try await persistOrThrow()
                    } catch {
                        // Review B5v2: a MIGRATION failure (key/disk/init) must
                        // NOT quarantine valid history. Keep the decoded
                        // document in memory, record the error, and continue —
                        // the data is safe (still plaintext on disk) and will
                        // be migrated on a later successful load.
                        lastWriteError = "history migration failed: \(String(describing: error))"
                        recoveryState = "plaintext history could not be encrypted yet — retry on next launch"
                        // Round-5 REQ-5: distinct pending-migration state.
                        storageState = .plaintextMigrationPending
                    }
                }
            }
            document.entries = HistoryStoragePolicy.trimmed(
                document.entries,
                policy: retention,
                now: Date())
        } catch let e as HistoryRepositoryError where e == .ioFailed {
            // Round-5 REQ-5: a storage READ failure is NOT corruption — do not
            // quarantine a valid file that could not be read. The state was
            // set above (storageReadFailure); rethrow without quarantine.
            throw e
        } catch {
            // Genuine CORRUPTION (unreadable/undecodable data): quarantine the
            // file and start clean (recoverable). Migration/key/disk errors are
            // handled above and do NOT reach here.
            // Round-5 REQ-5: distinct corrupt state (admission surfaces it).
            let quarantine = fileURL.appendingPathExtension("quarantined")
            try? fileSystem.move(fileURL, to: quarantine)
            document = HistoryDocument(entries: [])
            storageState = .corruptQuarantined
            throw HistoryRepositoryError.corruptionDetected
        }
        isInitialized = true
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
        // Review B8: transactional commit — build the new document, persist it
        // durably, and only on success assign it to `document`. A failed write
        // leaves both the in-memory and on-disk state consistent (entry not
        // added) and records the error.
        var candidate = document
        candidate.entries.insert(entry, at: 0)
        candidate.entries = HistoryStoragePolicy.trimmed(
            candidate.entries,
            policy: retention,
            now: Date())
        do {
            try await persistOrThrow(candidate)
            document = candidate
            lastWriteError = nil
        } catch {
            // On failure record the error and keep the old in-memory document
            // (state consistent with disk).
            lastWriteError = String(describing: error)
        }
    }

    public func entries() async -> [HistoryStorageEntry] { document.entries }

    public func clear() async throws {
        // Review B8: transactional — persist the cleared candidate first, then
        // commit; a failed write leaves both states consistent.
        let candidate = HistoryDocument(entries: [])
        try await persistOrThrow(candidate)
        document = candidate
    }

    public func delete(_ id: UUID) async throws {
        // Review B8: transactional delete.
        var candidate = document
        candidate.entries.removeAll { $0.id == id }
        try await persistOrThrow(candidate)
        document = candidate
    }

    /// True when a write would be allowed by policy (used by callers to skip
    /// non-normal sessions without touching the repository).
    public func allowsWrite(sensitivity: SessionSensitivity, outcome: InsertionOutcome?) -> Bool {
        HistoryStoragePolicy.allowsWrite(sensitivity: sensitivity, outcome: outcome)
    }

    // MARK: Persistence

    private func persist() async {
        await persistRecording()
    }

    private func persistOrThrow(_ doc: HistoryDocument? = nil) async throws {
        let toWrite = doc ?? document
        do {
            // Review B8: writes fail closed until the repository is
            // initialized (load completed), matching the declared contract.
            guard isInitialized else {
                lastWriteError = "history repository not initialized"
                throw HistoryRepositoryError.ioFailed
            }
            // Review R7: fail-closed writes. If sealed data exists but the key
            // is unavailable, or encryption was configured but the key is
            // missing NOW, refuse to write plaintext (never overwrite the
            // sealed file with plaintext).
            if sealedDataUnreadable {
                lastWriteError = "history key unavailable — refusing to overwrite sealed data"
                throw HistoryRepositoryError.permissionDenied
            }
            if encryptionConfigured, keyProvider() == nil {
                lastWriteError = "history encryption configured but key missing — refusing plaintext write"
                throw HistoryRepositoryError.permissionDenied
            }
            let data: Data
            if let key = keyProvider() {
                usingEncryption = true
                let encrypted = try HistoryEncryptionMigration.encrypt(
                    document: toWrite, key: key, engine: cipher)
                data = try encoder.encode(encrypted)
            } else {
                data = try encoder.encode(toWrite)
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

    /// Non-throwing persist used by policy-gated add(): records the error so
    /// it is never silent.
    private func persistRecording() async {
        do {
            try await persistOrThrow()
            lastWriteError = nil
        } catch {
            lastWriteError = String(describing: error)
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
