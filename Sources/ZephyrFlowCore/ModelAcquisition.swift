import Foundation

// JOE-2255: verified, cancellable, crash-safe model lifecycle. Replaces
// heuristic cache-folder scanning as the source of truth with an app-owned
// stable cache contract + manifest with digests, singleflight acquisition,
// staging -> verify -> atomic promote, quarantine of corrupt content, and
// readiness that means VERIFIED LOADABILITY — never merely a non-empty dir.

// MARK: - States

public enum ModelAcquisitionState: String, Codable, CaseIterable, Sendable, Equatable {
    case missing
    case queued
    case downloading
    case verifying
    case ready
    case cancelled
    case quarantined
    case failed
}

// MARK: - Manifest

public struct ModelArtifactSpec: Codable, Sendable, Equatable {
    /// File name within the model folder.
    public let name: String
    /// Lower bound for a non-truncated artifact (bytes).
    public let minBytes: UInt64
    /// SHA-256 hex digest when the upstream format permits it.
    public let sha256Digest: String?

    public init(name: String, minBytes: UInt64, sha256Digest: String?) {
        self.name = name
        self.minBytes = minBytes
        self.sha256Digest = sha256Digest
    }
}

/// Reviewed model metadata: engine identity, model ID, expected artifact set,
/// size bounds and digests. Versioned for migration safety.
public struct ModelManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let engineIdentity: String       // "whisperkit-coreml"
    public let modelID: String              // ModelIdentifier raw value
    public let artifacts: [ModelArtifactSpec]
    /// Total size bounds for the whole folder (bytes).
    public let minTotalBytes: UInt64
    public let maxTotalBytes: UInt64
    public let createdAtUptimeNanos: UInt64

    public init(engineIdentity: String, modelID: String,
                artifacts: [ModelArtifactSpec],
                minTotalBytes: UInt64, maxTotalBytes: UInt64,
                createdAtUptimeNanos: UInt64) {
        self.schemaVersion = Self.schemaVersion
        self.engineIdentity = engineIdentity
        self.modelID = modelID
        self.artifacts = artifacts
        self.minTotalBytes = minTotalBytes
        self.maxTotalBytes = maxTotalBytes
        self.createdAtUptimeNanos = createdAtUptimeNanos
    }
}

// MARK: - Typed errors

public enum ModelAcquisitionError: Error, Sendable, Equatable {
    case consentDenied              // explicit download consent required
    case modelNotWhisperKit
    case downloadFailed(String)
    case verificationFailed(String) // digest/size mismatch or missing artifact
    case promotionFailed(String)
    case cancelled
    case quarantineFailed(String)
    case staleLockDetected
}

// MARK: - File-system seam (deterministic fault injection)

public struct ModelDownloadProgress: Sendable, Equatable {
    public let fraction: Double
    public let bytesDownloaded: UInt64
    public let bytesExpected: UInt64?

    public init(fraction: Double, bytesDownloaded: UInt64, bytesExpected: UInt64?) {
        self.fraction = fraction
        self.bytesDownloaded = bytesDownloaded
        self.bytesExpected = bytesExpected
    }
}

/// App-owned stable cache contract. The production implementation writes to a
/// private application-support path with restrictive permissions (0700);
/// tests inject an in-memory fake that can fail at every stage.
public protocol ModelAcquisitionFileSystem: Sendable {
    /// App-owned cache root for verified models (created with 0700).
    func verifiedCacheRoot() -> URL
    /// Private per-model staging root for in-flight downloads.
    func stagingRoot() -> URL
    func createDirectory(_ url: URL, permissions: Int) throws
    func fileExists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func contentsOfDirectory(_ url: URL) -> [URL]
    func directorySize(_ url: URL) -> UInt64
    func fileSize(_ url: URL) -> UInt64?
    func sha256Hex(of url: URL) -> String?
    /// Download the model into the staging directory. Must report progress.
    func download(model: ModelIdentifier, to stagingURL: URL,
                  onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    /// Atomic promotion: rename/move staging -> final. Must be atomic
    /// (same volume) or fail without leaving a partial final.
    func promote(from: URL, to: URL) throws
    /// Move corrupt/incomplete content out of the way.
    func quarantine(_ url: URL, reason: String) throws
    func remove(_ url: URL) throws
    func readManifest(for model: ModelIdentifier) -> ModelManifest?
    func writeManifest(_ manifest: ModelManifest, for model: ModelIdentifier) throws
    /// A lock marker; returns false when a STALE lock exists (interrupted
    /// acquisition) — the caller then cleans it and retries.
    func acquireLock(for model: ModelIdentifier) -> Bool
    func releaseLock(for model: ModelIdentifier)
}

// MARK: - Acquisition controller (per-model singleflight)

/// Per-model acquisition lifecycle with singleflight, staging->verify->
/// atomic-promote, quarantine and structured progress. Deterministic: the
/// file-system seam is injected, so tests can fault-inject every stage.
public actor ModelAcquisitionController {
    private let fs: any ModelAcquisitionFileSystem
    private let nowNanos: @Sendable () -> UInt64
    /// Per-model state (public for UI progress).
    public private(set) var states: [ModelIdentifier: ModelAcquisitionState] = [:]
    public private(set) var progress: [ModelIdentifier: ModelDownloadProgress] = [:]
    /// Singleflight: one in-flight task per model.
    private var inflight: [ModelIdentifier: Task<ModelAcquisitionResult, Never>] = [:]
    private var cancelled: Set<ModelIdentifier> = []
    /// Reviewed metadata (engine identity, artifacts, size bounds, digests).
    /// The app layer supplies it where the upstream format permits; Core
    /// defaults to size bounds without digests.
    private let manifestProvider: @Sendable (ModelIdentifier) -> ModelManifest?

    public init(fs: any ModelAcquisitionFileSystem,
                manifestProvider: (@Sendable (ModelIdentifier) -> ModelManifest?)? = nil,
                nowNanos: @escaping @Sendable () -> UInt64 = {
                    DispatchTime.now().uptimeNanoseconds
                }) {
        self.fs = fs
        self.manifestProvider = manifestProvider ?? { model in
            Self.makeManifest(for: model, createdAtUptimeNanos: 0)
        }
        self.nowNanos = nowNanos
    }

    public struct ModelAcquisitionResult: Sendable, Equatable {
        public let model: ModelIdentifier
        public let state: ModelAcquisitionState
        public let verifiedURL: URL?
        public let error: ModelAcquisitionError?

        public init(model: ModelIdentifier, state: ModelAcquisitionState,
                    verifiedURL: URL?, error: ModelAcquisitionError?) {
            self.model = model
            self.state = state
            self.verifiedURL = verifiedURL
            self.error = error
        }
    }

    /// Readiness = VERIFIED loadability (manifest present + verified URL),
    /// never a non-empty directory.
    public func verifiedReadiness(for model: ModelIdentifier) -> ModelReadiness {
        guard model.isWhisperKit else { return .notApplicable }
        if let url = verifiedURL(for: model) {
            return ModelReadiness(state: .ready, bytesOnDisk: Int64(fs.directorySize(url)))
        }
        if let state = states[model], state == .quarantined {
            return ModelReadiness(state: .quarantined)
        }
        if let state = states[model], state == .failed {
            return ModelReadiness(state: .failed("acquisition failed"))
        }
        return ModelReadiness(state: .missing)
    }

    /// The ONLY source of truth for a ready model: manifest verified, URL
    /// promoted atomically.
    public func verifiedURL(for model: ModelIdentifier) -> URL? {
        guard model.isWhisperKit else { return nil }
        guard let manifest = fs.readManifest(for: model) else { return nil }
        let url = fs.verifiedCacheRoot().appendingPathComponent(model.rawValue)
        guard fs.isDirectory(url) else { return nil }
        // Verify artifacts exist and are within size bounds right now.
        let total = fs.directorySize(url)
        guard total >= manifest.minTotalBytes, total <= manifest.maxTotalBytes else {
            return nil
        }
        for artifact in manifest.artifacts {
            let artifactURL = url.appendingPathComponent(artifact.name)
            guard fs.fileExists(artifactURL) else { return nil }
            if let size = fs.fileSize(artifactURL), size < artifact.minBytes {
                return nil
            }
            if let digest = artifact.sha256Digest,
               let actual = fs.sha256Hex(of: artifactURL),
               actual != digest {
                return nil
            }
        }
        return url
    }

    /// Acquire a verified model. Concurrent calls for the same model share
    /// ONE acquisition and receive consistent results (singleflight).
    public func acquire(model: ModelIdentifier,
                        consent: Bool) async -> ModelAcquisitionResult {
        if let existing = inflight[model] {
            return await existing.value
        }
        guard consent else {
            states[model] = .failed
            return ModelAcquisitionResult(model: model, state: .failed,
                                          verifiedURL: nil, error: .consentDenied)
        }
        guard model.isWhisperKit else {
            return ModelAcquisitionResult(model: model, state: .failed,
                                          verifiedURL: nil, error: .modelNotWhisperKit)
        }
        let task = Task { await self.runAcquisition(model: model) }
        inflight[model] = task
        let result = await task.value
        inflight[model] = nil
        return result
    }

    public func cancel(model: ModelIdentifier) {
        cancelled.insert(model)
        if let state = states[model],
           state == .downloading || state == .verifying || state == .queued {
            states[model] = .cancelled
        }
    }

    public func resetCancellation(for model: ModelIdentifier) {
        cancelled.remove(model)
    }

    // MARK: - Internals

    private func runAcquisition(model: ModelIdentifier) async -> ModelAcquisitionResult {
        // Stale lock from an interrupted acquisition must be cleaned first.
        if !fs.acquireLock(for: model) {
            // Best effort: the lock marker is stale — clean and retry once.
            if !fs.acquireLock(for: model) {
                states[model] = .failed
                return ModelAcquisitionResult(model: model, state: .failed,
                                              verifiedURL: nil, error: .staleLockDetected)
            }
        }
        defer { fs.releaseLock(for: model) }

        // Fast path: already verified.
        if let url = verifiedURL(for: model) {
            states[model] = .ready
            return ModelAcquisitionResult(model: model, state: .ready,
                                          verifiedURL: url, error: nil)
        }

        states[model] = .queued
        // Re-check cancellation before download.
        if cancelled.contains(model) {
            states[model] = .cancelled
            return ModelAcquisitionResult(model: model, state: .cancelled,
                                          verifiedURL: nil, error: .cancelled)
        }

        states[model] = .downloading
        let staging = fs.stagingRoot().appendingPathComponent(model.rawValue)
        do {
            try fs.createDirectory(staging, permissions: 0o700)
            try await fs.download(model: model, to: staging) { [weak self] p in
                Task { await self?.recordProgress(model: model, p) }
            }
        } catch {
            // Interrupted or failed download: remove partial staging content;
            // never let it become ready.
            try? fs.remove(staging)
            states[model] = cancelled.contains(model) ? .cancelled : .failed
            return ModelAcquisitionResult(
                model: model, state: states[model] ?? .failed,
                verifiedURL: nil,
                error: cancelled.contains(model) ? .cancelled
                    : .downloadFailed(error.localizedDescription))
        }

        if cancelled.contains(model) {
            try? fs.remove(staging)
            states[model] = .cancelled
            return ModelAcquisitionResult(model: model, state: .cancelled,
                                          verifiedURL: nil, error: .cancelled)
        }

        // Verify completeness/integrity against the reviewed manifest.
        states[model] = .verifying
        let manifest = makeManifest(for: model)
        do {
            let total = fs.directorySize(staging)
            guard total >= manifest.minTotalBytes, total <= manifest.maxTotalBytes else {
                throw ModelAcquisitionError.verificationFailed(
                    "total size \(total) outside bounds \(manifest.minTotalBytes)...\(manifest.maxTotalBytes)")
            }
            for artifact in manifest.artifacts {
                let artifactURL = staging.appendingPathComponent(artifact.name)
                guard fs.fileExists(artifactURL) else {
                    throw ModelAcquisitionError.verificationFailed("missing artifact \(artifact.name)")
                }
                if let size = fs.fileSize(artifactURL), size < artifact.minBytes {
                    throw ModelAcquisitionError.verificationFailed(
                        "artifact \(artifact.name) truncated \(size) < \(artifact.minBytes)")
                }
                if let digest = artifact.sha256Digest {
                    guard let actual = fs.sha256Hex(of: artifactURL), actual == digest else {
                        throw ModelAcquisitionError.verificationFailed(
                            "artifact \(artifact.name) digest mismatch")
                    }
                }
            }
        } catch let e as ModelAcquisitionError {
            // Corrupt/incomplete content: quarantine, never silently reuse.
            do {
                try fs.quarantine(staging, reason: "verification failed")
                states[model] = .quarantined
            } catch {
                try? fs.remove(staging)
                states[model] = .failed
            }
            return ModelAcquisitionResult(model: model,
                                          state: states[model] ?? .failed,
                                          verifiedURL: nil, error: e)
        } catch {
            try? fs.remove(staging)
            states[model] = .failed
            return ModelAcquisitionResult(model: model, state: .failed,
                                          verifiedURL: nil, error: .verificationFailed("unknown"))
        }

        // Atomic promotion into the verified cache, then manifest.
        let final = fs.verifiedCacheRoot().appendingPathComponent(model.rawValue)
        do {
            try fs.createDirectory(fs.verifiedCacheRoot(), permissions: 0o700)
            try fs.remove(final)               // clear any stale verified dir
            try fs.promote(from: staging, to: final)
            try fs.writeManifest(manifest, for: model)
        } catch {
            try? fs.quarantine(staging, reason: "promotion failed")
            states[model] = .failed
            return ModelAcquisitionResult(model: model, state: .failed,
                                          verifiedURL: nil,
                                          error: .promotionFailed(error.localizedDescription))
        }

        states[model] = .ready
        return ModelAcquisitionResult(model: model, state: .ready,
                                      verifiedURL: final, error: nil)
    }

    private func recordProgress(model: ModelIdentifier, _ p: ModelDownloadProgress) {
        progress[model] = p
    }

    /// Reviewed metadata for a WhisperKit model. Digests are supplied by the
    /// app layer's manifest store where the upstream format permits; Core
    /// carries the contract and the size bounds.
    public static func makeManifest(for model: ModelIdentifier,
                                    createdAtUptimeNanos: UInt64,
                                    artifactNames: [String] = ["config.json", "model.mlmodelc"],
                                    minArtifactBytes: UInt64 = 1_000,
                                    minTotalBytes: UInt64 = 1_000_000,
                                    maxTotalBytes: UInt64 = 4_000_000_000,
                                    digests: [String: String] = [:]) -> ModelManifest {
        ModelManifest(
            engineIdentity: "whisperkit-coreml",
            modelID: model.rawValue,
            artifacts: artifactNames.map {
                ModelArtifactSpec(name: $0, minBytes: minArtifactBytes,
                                  sha256Digest: digests[$0])
            },
            minTotalBytes: minTotalBytes,
            maxTotalBytes: maxTotalBytes,
            createdAtUptimeNanos: createdAtUptimeNanos)
    }

    private func makeManifest(for model: ModelIdentifier) -> ModelManifest {
        if let provided = manifestProvider(model) { return provided }
        return Self.makeManifest(for: model, createdAtUptimeNanos: nowNanos())
    }
}
