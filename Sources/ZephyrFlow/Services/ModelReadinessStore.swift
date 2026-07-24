import Foundation
import SwiftUI
import Combine
import ZephyrFlowCore

/// Observable readiness for Whisper models (download / cache / fail).
@MainActor
final class ModelReadinessStore: ObservableObject {
    static let shared = ModelReadinessStore()

    @Published private(set) var readiness: [ModelIdentifier: ModelReadiness] = [:]
    @Published private(set) var bannerMessage: String?

    private var refreshTask: Task<Void, Never>?

    private init() {
        refreshAll()
    }

    func readiness(for model: ModelIdentifier) -> ModelReadiness {
        readiness[model] ?? ModelReadiness(state: model.isWhisperKit ? .missing : .notApplicable)
    }

    /// Scans disk off the main actor, then publishes.
    func refreshAll() {
        refreshTask?.cancel()
        let priorDownloading = readiness.filter {
            if case .downloading = $0.value.state { return true }
            return false
        }
        refreshTask = Task { [priorDownloading] in
            let map = await Task.detached(priority: .utility) {
                var built: [ModelIdentifier: ModelReadiness] = [:]
                for model in ModelIdentifier.allCases {
                    built[model] = WhisperModelLocator.readiness(for: model)
                }
                return built
            }.value
            var merged = map
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

    func markReady(_ model: ModelIdentifier) {
        Task {
            let ready = await Task.detached(priority: .utility) {
                WhisperModelLocator.readiness(for: model)
            }.value
            self.readiness[model] = ready
            if ready.state.isReady {
                self.bannerMessage = "\(model.displayName) ready"
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
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if bannerMessage?.contains("ready") == true {
                bannerMessage = nil
            }
        }
    }
}
