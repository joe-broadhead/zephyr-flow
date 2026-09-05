import CryptoKit
import Foundation
import Security
import ZephyrFlowCore

// JOE-2262: per-installation history encryption key in the Keychain.
// NON-synchronizing item with kSecAttrAccessibleAfterFirstUnlock — least
// permissive accessibility compatible with launch-at-login behavior. Key
// material never enters logs, metrics, backups, iCloud sync or support
// bundles.
actor HistoryKeychainStore {
    static let shared = HistoryKeychainStore()

    private let service = "com.zephyrflow.history-key"
    private let account = "installation"

    private init() {}

    /// Load the key, generating + storing it on first use.
    func loadOrCreate() -> HistoryCryptoKey? {
        if let existing = load() { return existing }
        return create()
    }

    func load() -> HistoryCryptoKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            return nil
        }
        return HistoryCryptoKey(keyID: keyID, material: data)
    }

    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Private

    private var keyID: String {
        // Content-free stable id of THIS installation's key (not the key).
        let digest = SHA256DigestHelper.sha256Hex("com.zephyrflow.history-key")
        return String(digest.prefix(16))
    }

    private func create() -> HistoryCryptoKey? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        let key = HistoryCryptoKey(keyID: keyID, material: Data(bytes))
        var query = baseQuery()
        query[kSecValueData as String] = key.material
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            // Duplicate race: another load already created it.
            return load()
        }
        return key
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

/// Minimal sha256 helper (CryptoKit wrapper) for the key ID.
enum SHA256DigestHelper {
    static func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
