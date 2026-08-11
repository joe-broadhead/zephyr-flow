import CryptoKit
import Foundation
import ZephyrFlowCore

// JOE-2255: app-owned stable cache contract for verified models.
// Primary source of truth = Application Support/ZephyrFlow/VerifiedModels
// (0700); readiness means manifest-verified loadability, never a non-empty
// directory. Downloads stage privately, verify, then promote atomically.

final class ProductionModelAcquisitionFileSystem: ModelAcquisitionFileSystem, @unchecked Sendable {
    private let fm = FileManager.default
    private let lock = NSLock()
    /// Lock markers: model -> acquisition start uptime nanos.
    private var lockTimestamps: [String: UInt64] = [:]
    private let staleLockNanos: UInt64 = 300_000_000_000  // 5 min
    private let downloader:
        @Sendable (ModelIdentifier, URL, @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> Void

    init(
        downloader:
            @escaping @Sendable (ModelIdentifier, URL, @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
            -> Void
    ) {
        self.downloader = downloader
    }

    func verifiedCacheRoot() -> URL {
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ZephyrFlow/VerifiedModels", isDirectory: true)
    }

    func stagingRoot() -> URL {
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ZephyrFlow/ModelStaging", isDirectory: true)
    }

    func createDirectory(_ url: URL, permissions: Int) throws {
        try fm.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions])
    }

    func fileExists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func contentsOfDirectory(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    func directorySize(_ url: URL) -> UInt64 {
        guard isDirectory(url) else { return 0 }
        guard
            let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true, let size = values.fileSize
            else { continue }
            total += UInt64(size)
        }
        return total
    }

    func fileSize(_ url: URL) -> UInt64? {
        // Round-6 B4: a directory bundle (e.g. a compiled .mlmodelc) reports
        // its RECURSIVE size — the directory-entry size is not meaningful.
        if isDirectory(url) { return directorySize(url) }
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    func sha256Hex(of url: URL) -> String? {
        // Round-6 B4: compiled Core ML models are DIRECTORY BUNDLES
        // (.mlmodelc) or .mlpackage trees, not single files. Hash
        // deterministically: SHA-256 over sorted relative paths + file
        // lengths + file bytes, so the digest covers every byte the loader
        // can consume and is stable across directory layouts.
        if isDirectory(url) {
            guard
                let files = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { return nil }
            var entries: [(relative: String, data: Data)] = []
            for case let fileURL as URL in files {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                    values.isRegularFile == true,
                    let data = try? Data(contentsOf: fileURL)
                else { continue }
                let rel = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                entries.append((rel, data))
            }
            entries.sort { $0.relative < $1.relative }
            var hasher = SHA256()
            for (rel, data) in entries {
                hasher.update(data: Data(rel.utf8))
                hasher.update(data: withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The download closure (app-provided, e.g. WhisperKit load + stage copy)
    /// populates the staging directory. Progress is relayed through.
    func download(
        model: ModelIdentifier, to stagingURL: URL,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await downloader(model, stagingURL, onProgress)
    }

    func promote(from: URL, to: URL) throws {
        // Same-volume atomic rename.
        try fm.moveItem(at: from, to: to)
    }

    func quarantine(_ url: URL, reason: String) throws {
        let base = stagingRoot().appendingPathComponent("Quarantine", isDirectory: true)
        try fm.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = base.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        try fm.moveItem(at: url, to: target)
    }

    func remove(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    func readManifest(for model: ModelIdentifier) -> ModelManifest? {
        let url = verifiedCacheRoot().appendingPathComponent(model.rawValue)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }

    func writeManifest(_ manifest: ModelManifest, for model: ModelIdentifier) throws {
        let dir = verifiedCacheRoot().appendingPathComponent(model.rawValue, isDirectory: true)
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// Stale-lock detection: a lock older than the threshold (interrupted
    /// acquisition) is cleaned and re-acquired.
    func acquireLock(for model: ModelIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = model.rawValue
        let now = DispatchTime.now().uptimeNanoseconds
        if let existing = lockTimestamps[key] {
            if now &- existing >= staleLockNanos {
                // Stale lock from a crashed/interrupted acquisition.
                lockTimestamps[key] = now
                return true
            }
            return false
        }
        lockTimestamps[key] = now
        return true
    }

    func releaseLock(for model: ModelIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        lockTimestamps.removeValue(forKey: model.rawValue)
    }
}

// MARK: - Production downloader (WhisperKit)

extension ProductionModelAcquisitionFileSystem {
    /// Downloads via WhisperKit (respecting consent), then stages the located
    /// model folder into the private staging path for verification+promotion.
    /// If a verified model already exists, staging is skipped by the caller.
    static let whisperKitDownloader:
        @Sendable (ModelIdentifier, URL, @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> Void = {
            model, stagingURL, onProgress in
            guard model.isWhisperKit else {
                throw ModelAcquisitionError.modelNotWhisperKit
            }
            // WhisperKit downloads into its own cache; we then copy the located
            // folder into OUR staging area so verification/promotion is app-owned.
            onProgress(ModelDownloadProgress(fraction: 0.05, bytesDownloaded: 0, bytesExpected: nil))
            let engine = WhisperKitEngine()
            try await engine.load(model: model, allowDownload: true)
            onProgress(ModelDownloadProgress(fraction: 0.5, bytesDownloaded: 0, bytesExpected: nil))
            guard let located = WhisperModelLocator.locate(model) else {
                throw ModelAcquisitionError.downloadFailed("model not located after download")
            }
            let fm = FileManager.default
            try fm.createDirectory(
                at: stagingURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Stage a private copy (never a symlink into a third-party cache).
            let items = try fm.contentsOfDirectory(
                at: located,
                includingPropertiesForKeys: nil)
            for item in items {
                let dest = stagingURL.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: dest)
            }
            // Round-6 B4: stage the complete TOKENIZER directory (tokenizer.json
            // + its configuration files) into a tokenizer/ subfolder so the
            // verified artifact is self-contained and the pinned loader's
            // Hub-download tokenizer fallback can be disabled.
            if let tokenizerDir = WhisperTokenizerLocator.locate() {
                let tokenizerDest = stagingURL.appendingPathComponent("tokenizer")
                try fm.createDirectory(
                    at: tokenizerDest, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let tItems = try fm.contentsOfDirectory(
                    at: tokenizerDir,
                    includingPropertiesForKeys: nil)
                for tItem in tItems {
                    let dest = tokenizerDest.appendingPathComponent(tItem.lastPathComponent)
                    try fm.copyItem(at: tItem, to: dest)
                }
            }
            onProgress(ModelDownloadProgress(fraction: 1.0, bytesDownloaded: 0, bytesExpected: nil))
        }
}
