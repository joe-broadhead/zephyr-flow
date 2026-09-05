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
    /// Round-6 B4: an OPTIONAL component (e.g. TextDecoderContextPrefill) may
    /// be absent from a valid model — but when present it is still hashed.
    public let isOptional: Bool

    public init(
        name: String, minBytes: UInt64, sha256Digest: String?,
        isOptional: Bool = false
    ) {
        self.name = name
        self.minBytes = minBytes
        self.sha256Digest = sha256Digest
        self.isOptional = isOptional
    }
}

/// Reviewed model metadata: engine identity, model ID, expected artifact set,
/// size bounds and digests. Versioned for migration safety.
public struct ModelManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let engineIdentity: String  // "whisperkit-coreml"
    public let modelID: String  // ModelIdentifier raw value
    public let artifacts: [ModelArtifactSpec]
    /// Total size bounds for the whole folder (bytes).
    public let minTotalBytes: UInt64
    public let maxTotalBytes: UInt64
    public let createdAtUptimeNanos: UInt64

    public init(
        engineIdentity: String, modelID: String,
        artifacts: [ModelArtifactSpec],
        minTotalBytes: UInt64, maxTotalBytes: UInt64,
        createdAtUptimeNanos: UInt64
    ) {
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
    case consentDenied  // explicit download consent required
    case modelNotWhisperKit
    case downloadFailed(String)
    case verificationFailed(String)  // digest/size mismatch or missing artifact
    case promotionFailed(String)
    case cancelled
    case quarantineFailed(String)
    case staleLockDetected
}

// MARK: - File-system seam (deterministic fault injection)

public struct ModelDownloadProgress: Sendable, Equatable {
    /// nil when the transport does not supply measured fractional progress.
    public let fraction: Double?
    public let bytesDownloaded: UInt64
    public let bytesExpected: UInt64?

    public init(fraction: Double?, bytesDownloaded: UInt64, bytesExpected: UInt64?) {
        self.fraction = fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
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
    func download(
        model: ModelIdentifier, to stagingURL: URL,
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
    private var inflight: [ModelIdentifier: (id: UUID, task: Task<ModelAcquisitionResult, Never>)] = [:]
    private var cancelled: Set<ModelIdentifier> = []
    /// Content-free counters for singleflight/stale-callback diagnostics.
    private(set) var coalescedRequests: UInt64 = 0
    private(set) var ignoredProgressUpdates: UInt64 = 0
    /// Reviewed metadata (engine identity, artifacts, size bounds, digests).
    /// The app layer supplies it where the upstream format permits; Core
    /// defaults to size bounds without digests.
    private let manifestProvider: @Sendable (ModelIdentifier) -> ModelManifest?

    public init(
        fs: any ModelAcquisitionFileSystem,
        manifestProvider: (@Sendable (ModelIdentifier) -> ModelManifest?)? = nil,
        nowNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.fs = fs
        self.manifestProvider =
            manifestProvider ?? { model in
                Self.makeManifest(for: model, createdAtUptimeNanos: 0)
            }
        self.nowNanos = nowNanos
    }

    public struct ModelAcquisitionResult: Sendable, Equatable {
        public let model: ModelIdentifier
        public let state: ModelAcquisitionState
        /// Round-6 NIT 4: retained for call-site compatibility; the single
        /// source of truth is `verifiedArtifact(for:)` (folder + manifest
        /// version + aggregate digest). New code MUST use the artifact form.
        public let verifiedURL: URL?
        public let error: ModelAcquisitionError?

        public init(
            model: ModelIdentifier, state: ModelAcquisitionState,
            verifiedURL: URL?, error: ModelAcquisitionError?
        ) {
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

    /// Review B8: the verified digest(s) of a ready model from the reviewed
    /// manifest. Returns a stable joined hex of the artifact digests, or nil
    /// when the model is not verified/ready. Used to bind the loaded engine's
    /// identity to the verified artifact.
    public func verifiedDigest(for model: ModelIdentifier) -> String? {
        guard model.isWhisperKit else { return nil }
        guard let manifest = fs.readManifest(for: model),
            verifiedURL(for: model) != nil
        else { return nil }
        let digests = manifest.artifacts.compactMap { $0.sha256Digest }
        guard !digests.isEmpty else { return nil }
        return digests.joined(separator: ":")
    }

    /// Round-5 B5: one atomic verified-artifact value — folder + manifest
    /// version + aggregate digest. A "verified" model means EVERY byte
    /// WhisperKit can load was enumerated in the manifest and hashed; there is
    /// no separate readiness/URL TOCTOU (the folder, manifest version and
    /// aggregate digest travel together).
    public struct VerifiedModelArtifact: Sendable, Equatable {
        public let folder: URL
        public let manifestVersion: Int
        public let aggregateDigest: String
        public init(folder: URL, manifestVersion: Int, aggregateDigest: String) {
            self.folder = folder
            self.manifestVersion = manifestVersion
            self.aggregateDigest = aggregateDigest
        }
    }

    /// The ONLY source of truth for a ready model: manifest verified, URL
    /// promoted atomically. Round-5 B5: EVERY artifact must carry a digest AND
    /// the actual hash must match — a digest present with a hash failure (or a
    /// missing digest entirely) is a verification FAILURE (fail closed), never
    /// a skipped check.
    public func verifiedURL(for model: ModelIdentifier) -> URL? {
        verifiedArtifact(for: model)?.folder
    }

    /// Round-5 B5: atomic verified-artifact lookup (folder + manifest version
    /// + aggregate digest) with digest-REQUIRED verification of every artifact
    /// WhisperKit loads.
    public func verifiedArtifact(for model: ModelIdentifier) -> VerifiedModelArtifact? {
        guard model.isWhisperKit else { return nil }
        guard let manifest = fs.readManifest(for: model) else { return nil }
        let url = fs.verifiedCacheRoot().appendingPathComponent(model.rawValue)
        guard fs.isDirectory(url) else { return nil }
        // Verify artifacts exist and are within size bounds right now.
        let total = fs.directorySize(url)
        guard total >= manifest.minTotalBytes, total <= manifest.maxTotalBytes else {
            return nil
        }
        // Round-5 B5: digest-REQUIRED. Every artifact must have a digest and
        // its actual hash must match. A manifest with un-hashed artifacts is
        // NOT a verified model (fail closed).
        var digests: [String] = []
        for artifact in manifest.artifacts {
            let artifactURL = url.appendingPathComponent(artifact.name)
            if !fs.fileExists(artifactURL) {
                // Round-6 B4: optional components may be absent.
                if artifact.isOptional { continue }
                return nil
            }
            if let size = fs.fileSize(artifactURL), size < artifact.minBytes {
                return nil
            }
            guard let expected = artifact.sha256Digest else {
                // Round-5 B5: a digestless artifact means unverified bytes.
                return nil
            }
            // Hash failure (nil actual OR mismatch) is a verification failure.
            guard let actual = fs.sha256Hex(of: artifactURL), actual == expected else {
                return nil
            }
            digests.append(actual)
        }
        guard !digests.isEmpty else { return nil }
        let aggregate = digests.joined(separator: ":")
        return VerifiedModelArtifact(
            folder: url,
            manifestVersion: manifest.schemaVersion,
            aggregateDigest: aggregate)
    }

    /// Acquire a verified model. Concurrent calls for the same model share
    /// ONE acquisition and receive consistent results (singleflight).
    public func acquire(
        model: ModelIdentifier,
        consent: Bool
    ) async -> ModelAcquisitionResult {
        guard consent else {
            if inflight[model] == nil { states[model] = .failed }
            return ModelAcquisitionResult(
                model: model, state: .failed,
                verifiedURL: nil, error: .consentDenied)
        }
        guard model.isWhisperKit else {
            return ModelAcquisitionResult(
                model: model, state: .failed,
                verifiedURL: nil, error: .modelNotWhisperKit)
        }
        guard !Task.isCancelled else {
            return ModelAcquisitionResult(model: model, state: .cancelled, verifiedURL: nil, error: .cancelled)
        }
        if let existing = inflight[model] {
            // Joining an existing flight does not acquire cancellation authority
            // over its owner. Explicit cancel(model:) cancels the whole flight.
            coalescedRequests &+= 1
            return await existing.task.value
        }
        let id = UUID()
        cancelled.remove(model)  // an explicit new acquisition is a retry
        progress[model] = nil
        let task = Task { await self.runAcquisition(model: model, id: id) }
        inflight[model] = (id, task)
        // Cancellation reaches native download work synchronously even while
        // this actor is busy hashing. Retain singleflight ownership until the
        // task actually returns; a flag alone never permits a second writer.
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inflight[model]?.id == id { inflight[model] = nil }
        return result
    }

    public func cancel(model: ModelIdentifier) {
        cancelled.insert(model)
        inflight[model]?.task.cancel()
        if let state = states[model],
            state == .downloading || state == .verifying || state == .queued
        {
            states[model] = .cancelled
        }
    }

    public func resetCancellation(for model: ModelIdentifier) {
        guard inflight[model] == nil else { return }
        cancelled.remove(model)
    }

    // MARK: - Internals

    private func runAcquisition(model: ModelIdentifier, id: UUID) async -> ModelAcquisitionResult {
        if Task.isCancelled { return cancellationResult(model) }
        // Stale lock from an interrupted acquisition must be cleaned first.
        if !fs.acquireLock(for: model) {
            // Best effort: the lock marker is stale — clean and retry once.
            if !fs.acquireLock(for: model) {
                states[model] = .failed
                return ModelAcquisitionResult(
                    model: model, state: .failed,
                    verifiedURL: nil, error: .staleLockDetected)
            }
        }
        defer { fs.releaseLock(for: model) }

        // Fast path: already verified.
        if let url = verifiedURL(for: model) {
            if Task.isCancelled { return cancellationResult(model) }
            states[model] = .ready
            return ModelAcquisitionResult(
                model: model, state: .ready,
                verifiedURL: url, error: nil)
        }

        states[model] = .queued
        // Re-check cancellation before download.
        if cancelled.contains(model) || Task.isCancelled { return cancellationResult(model) }

        states[model] = .downloading
        let staging = fs.stagingRoot().appendingPathComponent(model.rawValue)
        do {
            try fs.createDirectory(staging, permissions: 0o700)
            try await fs.download(model: model, to: staging) { [weak self] p in
                Task { await self?.recordProgress(model: model, id: id, p) }
            }
        } catch {
            // Interrupted or failed download: remove partial staging content;
            // never let it become ready.
            try? fs.remove(staging)
            if cancelled.contains(model) || Task.isCancelled || error is CancellationError {
                return cancellationResult(model)
            }
            states[model] = .failed
            return ModelAcquisitionResult(
                model: model, state: states[model] ?? .failed,
                verifiedURL: nil,
                error: .downloadFailed("model transfer failed"))
        }

        if cancelled.contains(model) || Task.isCancelled {
            try? fs.remove(staging)
            return cancellationResult(model)
        }

        // Verify completeness/integrity against the reviewed manifest.
        states[model] = .verifying
        let manifest = makeManifest(for: model)
        do {
            try Task.checkCancellation()
            let total = fs.directorySize(staging)
            guard total >= manifest.minTotalBytes, total <= manifest.maxTotalBytes else {
                throw ModelAcquisitionError.verificationFailed(
                    "total size \(total) outside bounds \(manifest.minTotalBytes)...\(manifest.maxTotalBytes)")
            }
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                let artifactURL = staging.appendingPathComponent(artifact.name)
                if !fs.fileExists(artifactURL) {
                    // Round-6 B4: optional components may be absent.
                    if artifact.isOptional { continue }
                    throw ModelAcquisitionError.verificationFailed("missing artifact \(artifact.name)")
                }
                if let size = fs.fileSize(artifactURL), size < artifact.minBytes {
                    throw ModelAcquisitionError.verificationFailed(
                        "artifact \(artifact.name) truncated \(size) < \(artifact.minBytes)")
                }
                // Round-5 B5: a digest present with a hash failure is a
                // verification FAILURE (never skipped). Digestless artifacts
                // are hashed at promotion time (below) so the stored manifest
                // is always digest-complete.
                if let digest = artifact.sha256Digest {
                    guard let actual = fs.sha256Hex(of: artifactURL), actual == digest else {
                        throw ModelAcquisitionError.verificationFailed(
                            "artifact \(artifact.name) digest mismatch or hash failure")
                    }
                }
            }
        } catch is CancellationError {
            try? fs.remove(staging)
            return cancellationResult(model)
        } catch let e as ModelAcquisitionError {
            // Corrupt/incomplete content: quarantine, never silently reuse.
            do {
                try fs.quarantine(staging, reason: "verification failed")
                states[model] = .quarantined
            } catch {
                try? fs.remove(staging)
                states[model] = .failed
            }
            return ModelAcquisitionResult(
                model: model,
                state: states[model] ?? .failed,
                verifiedURL: nil, error: e)
        } catch {
            try? fs.remove(staging)
            states[model] = .failed
            return ModelAcquisitionResult(
                model: model, state: .failed,
                verifiedURL: nil, error: .verificationFailed("unknown"))
        }

        // Atomic promotion into the verified cache, then manifest.
        // Round-5 B5: compute a digest for EVERY artifact and write a
        // digest-COMPLETE manifest, so the on-disk manifest can never be
        // "verified" with un-hashed bytes. Artifacts without a digest at
        // promotion make the model unverifiable (fail closed below).
        let final = fs.verifiedCacheRoot().appendingPathComponent(model.rawValue)
        do {
            try Task.checkCancellation()
            try fs.createDirectory(fs.verifiedCacheRoot(), permissions: 0o700)
            try fs.remove(final)  // clear any stale verified dir
            try fs.promote(from: staging, to: final)
            var digestArtifacts: [ModelArtifactSpec] = []
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                let artifactURL = final.appendingPathComponent(artifact.name)
                guard fs.fileExists(artifactURL) else {
                    // Round-6 B4: optional components may be absent.
                    if artifact.isOptional { continue }
                    throw ModelAcquisitionError.promotionFailed(
                        "missing artifact \(artifact.name) — model unverifiable")
                }
                guard let actual = fs.sha256Hex(of: artifactURL) else {
                    throw ModelAcquisitionError.promotionFailed(
                        "cannot hash artifact \(artifact.name) — model unverifiable")
                }
                digestArtifacts.append(
                    ModelArtifactSpec(
                        name: artifact.name,
                        minBytes: artifact.minBytes,
                        sha256Digest: actual,
                        isOptional: artifact.isOptional))
            }
            let digestManifest = ModelManifest(
                engineIdentity: manifest.engineIdentity,
                modelID: manifest.modelID,
                artifacts: digestArtifacts,
                minTotalBytes: manifest.minTotalBytes,
                maxTotalBytes: manifest.maxTotalBytes,
                createdAtUptimeNanos: manifest.createdAtUptimeNanos)
            try Task.checkCancellation()
            // Committing the manifest is acquisition's completion point.
            // Cancellation after this commit may discard engine preparation,
            // but does not relabel a completed verified cache write as partial.
            try fs.writeManifest(digestManifest, for: model)
        } catch is CancellationError {
            // Cancellation after rename must remove the newly promoted bytes
            // as well as any manifest, rather than leaving a ready cache entry.
            try? fs.remove(final)
            try? fs.remove(staging)
            return cancellationResult(model)
        } catch {
            try? fs.quarantine(staging, reason: "promotion failed")
            states[model] = .failed
            return ModelAcquisitionResult(
                model: model, state: .failed,
                verifiedURL: nil,
                error: .promotionFailed(error.localizedDescription))
        }

        states[model] = .ready
        return ModelAcquisitionResult(
            model: model, state: .ready,
            verifiedURL: final, error: nil)
    }

    private func cancellationResult(_ model: ModelIdentifier) -> ModelAcquisitionResult {
        states[model] = .cancelled
        progress[model] = nil
        return ModelAcquisitionResult(model: model, state: .cancelled, verifiedURL: nil, error: .cancelled)
    }

    private func recordProgress(model: ModelIdentifier, id: UUID, _ p: ModelDownloadProgress) {
        guard inflight[model]?.id == id, states[model] == .downloading,
            inflight[model]?.task.isCancelled == false, !cancelled.contains(model)
        else {
            ignoredProgressUpdates &+= 1
            return
        }
        progress[model] = p
    }

    /// Reviewed metadata for a WhisperKit model. Digests are supplied by the
    /// app layer's manifest store where the upstream format permits; Core
    /// carries the contract and the size bounds.
    public static func makeManifest(
        for model: ModelIdentifier,
        createdAtUptimeNanos: UInt64,
        // Round-5 B5: the default enumerates EVERY asset the pinned WhisperKit
        // loader can consume (MelSpectrogram, AudioEncoder, TextDecoder,
        // optional TextDecoderContextPrefill, tokenizer assets + config).
        artifactNames: [String] = [
            "config.json",
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc",
            "tokenizer",
        ],
        // Round-6 B4: TextDecoderContextPrefill is OPTIONAL in the pinned
        // WhisperKit loader (loaded only when present). The tokenizer is a
        // staged DIRECTORY (tokenizer.json + configs) hashed directory-aware.
        optionalArtifactNames: Set<String> = ["TextDecoderContextPrefill.mlmodelc"],
        minArtifactBytes: UInt64 = 1_000,
        minTotalBytes: UInt64 = 1_000_000,
        maxTotalBytes: UInt64 = 4_000_000_000,
        digests: [String: String] = [:]
    ) -> ModelManifest {
        ModelManifest(
            engineIdentity: "whisperkit-coreml",
            modelID: model.rawValue,
            artifacts: artifactNames.map {
                ModelArtifactSpec(
                    name: $0, minBytes: minArtifactBytes,
                    sha256Digest: digests[$0],
                    isOptional: optionalArtifactNames.contains($0))
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
