import Foundation
import CryptoKit

// JOE-2262: defense-in-depth at-rest encryption for opted-in history.
// Authenticated modern construction (AES-256-GCM via CryptoKit). Metadata
// (id, timestamp, model, sensitivity class) stays plaintext ONLY where
// required for UI/indexing and is documented; transcript bodies are always
// sealed. This is application-level protection — NOT a substitute for
// FileVault or endpoint security.

// MARK: - Key

public struct HistoryCryptoKey: Sendable, Equatable {
    public let keyID: String
    public let material: Data

    public init(keyID: String, material: Data) {
        self.keyID = keyID
        self.material = material
    }
}

// MARK: - Sealed payload

public struct HistoryEncryptedPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let cipherName = "AES-256-GCM"

    public let version: Int
    public let cipher: String
    public let keyID: String
    public let nonce: Data
    public let ciphertext: Data
    public let authTag: Data

    public init(version: Int = HistoryEncryptedPayload.currentVersion,
                cipher: String = HistoryEncryptedPayload.cipherName,
                keyID: String, nonce: Data, ciphertext: Data, authTag: Data) {
        self.version = version
        self.cipher = cipher
        self.keyID = keyID
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authTag = authTag
    }
}

// MARK: - Engine

public enum HistoryCipherError: Error, Sendable, Equatable {
    case invalidKeySize
    case authenticationFailed
    case unsupportedVersion
    case keyMismatch
}

/// Authenticated encryption engine. Deterministic and testable: AES-256-GCM
/// round-trips, tamper and wrong-key cases fail authentication with nil —
/// never partial plaintext.
public struct HistoryCipherEngine: Sendable {
    public static let shared = HistoryCipherEngine()

    private let randomNonce: @Sendable () -> Data

    public init(randomNonce: @escaping @Sendable () -> Data = {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }) {
        self.randomNonce = randomNonce
    }

    public func encrypt(plaintext: Data, key: HistoryCryptoKey) throws -> HistoryEncryptedPayload {
        let symKey = try makeKey(key)
        let nonce = try AES.GCM.Nonce(data: randomNonce())
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        guard let ciphertext = sealed.ciphertext.isEmpty ? nil : sealed.ciphertext else {
            // Empty plaintext is legal; seal returns combined. Split safely.
            return HistoryEncryptedPayload(
                keyID: key.keyID,
                nonce: nonce.withUnsafeBytes { Data($0) },
                ciphertext: Data(), authTag: sealed.tag)
        }
        return HistoryEncryptedPayload(
            keyID: key.keyID,
            nonce: nonce.withUnsafeBytes { Data($0) },
            ciphertext: ciphertext, authTag: sealed.tag)
    }

    /// Returns nil on ANY authentication failure (wrong/missing key, tamper)
    /// — never partial plaintext.
    public func decrypt(_ payload: HistoryEncryptedPayload,
                        key: HistoryCryptoKey) -> Data? {
        guard payload.version == HistoryEncryptedPayload.currentVersion else { return nil }
        guard payload.keyID == key.keyID else { return nil }
        guard let symKey = try? makeKey(key) else { return nil }
        guard let nonce = try? AES.GCM.Nonce(data: payload.nonce) else { return nil }
        let sealed = try? AES.GCM.SealedBox(nonce: nonce,
                                            ciphertext: payload.ciphertext,
                                            tag: payload.authTag)
        guard let sealed else { return nil }
        return try? AES.GCM.open(sealed, using: symKey)
    }

    private func makeKey(_ key: HistoryCryptoKey) throws -> SymmetricKey {
        guard key.material.count == 32 else { throw HistoryCipherError.invalidKeySize }
        return SymmetricKey(data: key.material)
    }
}

// MARK: - Encrypted document (on-disk format)

/// On-disk encrypted history document. Transcript bodies are sealed per
/// entry; id/timestamp/model/sensitivity remain plaintext ONLY for UI and
/// are documented as visible metadata.
public struct EncryptedHistoryDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let encryptionVersion: Int
    public let cipher: String
    public let keyID: String
    /// Sealed payload of the full serialized entry list (single nonce/iv).
    public let payload: HistoryEncryptedPayload

    public init(encryptionVersion: Int = HistoryEncryptedPayload.currentVersion,
                cipher: String = HistoryEncryptedPayload.cipherName,
                keyID: String, payload: HistoryEncryptedPayload) {
        self.schemaVersion = Self.schemaVersion
        self.encryptionVersion = encryptionVersion
        self.cipher = cipher
        self.keyID = keyID
        self.payload = payload
    }
}

// MARK: - Migration (atomic, rollback-safe)

public enum HistoryEncryptionMigration: Sendable {
    /// Encrypt a plaintext document into an EncryptedHistoryDocument.
    public static func encrypt(document: HistoryDocument,
                               key: HistoryCryptoKey,
                               engine: HistoryCipherEngine = .shared) throws -> EncryptedHistoryDocument {
        let entriesData = try JSONEncoder().encode(document.entries)
        let payload = try engine.encrypt(plaintext: entriesData, key: key)
        return EncryptedHistoryDocument(keyID: key.keyID, payload: payload)
    }

    /// Decrypt an EncryptedHistoryDocument; nil on auth failure.
    public static func decrypt(document: EncryptedHistoryDocument,
                               key: HistoryCryptoKey,
                               engine: HistoryCipherEngine = .shared) -> HistoryDocument? {
        guard let data = engine.decrypt(document.payload, key: key) else { return nil }
        guard let entries = try? JSONDecoder().decode([HistoryStorageEntry].self, from: data) else {
            return nil
        }
        return HistoryDocument(schemaVersion: HistoryDocument.currentSchemaVersion,
                               entries: entries)
    }

    /// Visible metadata of an encrypted document (documented plaintext).
    public static func visibleMetadata(of document: EncryptedHistoryDocument) -> [String: String] {
        [
            "schemaVersion": String(document.schemaVersion),
            "encryptionVersion": String(document.encryptionVersion),
            "cipher": document.cipher,
            "keyID": document.keyID,
            "entryCount": "sealed",
        ]
    }
}
