import Combine
import Foundation
import SwiftUI
import ZephyrFlowCore

/// Observable artifact verification for Whisper models (manifest + digest +
/// size bounds), not engine readiness. EnginePreparationCoordinator separately
/// loads a current candidate before allowing session admission.
/// Downloads go through the app-owned verified cache with singleflight,
/// staging -> verify -> atomic promote, quarantine and explicit consent.
@MainActor
final class ModelReadinessStore: ObservableObject {
    static let shared = ModelReadinessStore()

    @Published private(set) var readiness: [ModelIdentifier: ModelReadiness] = [:]
    @Published private(set) var bannerMessage: String?

    private var refreshTask: Task<Void, Never>?
    /// App-owned verified-cache controller (production filesystem).
    private let acquisition = ModelAcquisitionController(
        fs: ProductionModelAcquisitionFileSystem(downloader: ProductionModelAcquisitionFileSystem.whisperKitDownloader))
    private var acquisitionTasks: [ModelIdentifier: Task<ModelAcquisitionController.ModelAcquisitionResult, Never>] =
        [:]

    private init() {
        refreshAll()
    }

    func readiness(for model: ModelIdentifier) -> ModelReadiness {
        readiness[model] ?? ModelReadiness(state: model.isWhisperKit ? .missing : .notApplicable)
    }

    /// JOE-2283: preflight free disk space before a download starts.
    static func freeDiskSpace() -> UInt64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    /// Verified readiness from the acquisition controller (source of truth).
    func verifiedReadiness(for model: ModelIdentifier) async -> ModelReadiness {
        await acquisition.verifiedReadiness(for: model)
    }

    /// Review B8: verified artifact digest for a ready model.
    func verifiedDigest(for model: ModelIdentifier) async -> String? {
        await acquisition.verifiedDigest(for: model)
    }

    /// Review B6v2: the promoted, verified artifact directory (nil when no
    /// verified artifact is on disk). The engine must load from here, not
    /// from WhisperKit's own cache.
    /// Round-5 B5: atomic VerifiedModelArtifact — the folder, manifest version
    /// and aggregate digest travel together (no readiness/URL TOCTOU).
    func verifiedURL(for model: ModelIdentifier) async -> URL? {
        await acquisition.verifiedArtifact(for: model)?.folder
    }

    /// Round-5 B5: atomic verified-artifact value for admission.
    func verifiedArtifact(for model: ModelIdentifier) async -> ModelAcquisitionController.VerifiedModelArtifact? {
        await acquisition.verifiedArtifact(for: model)
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var built: [ModelIdentifier: ModelReadiness] = [:]
            for model in ModelIdentifier.allCases {
                built[model] = await self.acquisition.verifiedReadiness(for: model)
            }
            guard !Task.isCancelled else { return }
            let priorDownloading = self.readiness.filter {
                if case .downloading = $0.value.state { return true }
                return false
            }
            var merged = built
            for (model, prior) in priorDownloading {
                merged[model] = prior
            }
            self.readiness = merged
        }
    }

    func markDownloading(_ model: ModelIdentifier, progress: Double?) {
        readiness[model] = ModelReadiness(state: .downloading(progress))
        bannerMessage = "Downloading \(model.displayName)…"
    }

    /// Acquire a VERIFIED model. `consent` = explicit download consent
    /// (settings.allowModelDownloads), independent of Local Only audio policy.
    /// Concurrent requests share ONE acquisition (singleflight).
    func acquire(_ model: ModelIdentifier, consent: Bool) async -> ModelAcquisitionController.ModelAcquisitionResult {
        guard consent, !Task.isCancelled else {
            return .init(
                model: model, state: Task.isCancelled ? .cancelled : .failed, verifiedURL: nil,
                error: Task.isCancelled ? .cancelled : .consentDenied)
        }
        if let existing = acquisitionTasks[model] {
            return await existing.value
        }
        let task = Task { await self.acquisition.acquire(model: model, consent: consent) }
        acquisitionTasks[model] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        acquisitionTasks[model] = nil
        switch result.state {
        case .downloading, .queued:
            markDownloading(model, progress: nil)
        case .ready:
            readiness[model] = ModelReadiness(
                state: .ready,
                bytesOnDisk: nil)
            bannerMessage = "\(model.displayName) files verified"
            clearBannerLater()
        case .cancelled:
            readiness[model] = ModelReadiness(state: .cancelled)
        case .quarantined:
            readiness[model] = ModelReadiness(state: .quarantined)
            bannerMessage = "\(model.displayName) corrupt content quarantined"
        case .failed:
            readiness[model] = ModelReadiness(
                state: .failed(result.error?.localizedDescription ?? "acquisition failed"))
            bannerMessage = "\(model.displayName): acquisition failed"
        case .missing, .verifying:
            readiness[model] = ModelReadiness(state: .missing)
        }
        return result
    }

    func markReady(_ model: ModelIdentifier) {
        Task { [weak self] in
            guard let self else { return }
            let ready = await self.acquisition.verifiedReadiness(for: model)
            self.readiness[model] = ready
            if ready.state.isReady {
                self.bannerMessage = "\(model.displayName) files verified"
                self.clearBannerLater()
            }
        }
    }

    func markFailed(_ model: ModelIdentifier, message: String) {
        readiness[model] = ModelReadiness(state: .failed(message))
        bannerMessage = "\(model.displayName): \(message)"
    }

    func clearBanner() {
        bannerMessage = nil
    }

    private func clearBannerLater() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.bannerMessage = nil
        }
    }
}
