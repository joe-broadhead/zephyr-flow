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

    private init() {
        refreshAll()
    }

    func readiness(for model: ModelIdentifier) -> ModelReadiness {
        readiness[model] ?? WhisperModelLocator.readiness(for: model)
    }

    func refreshAll() {
        var map: [ModelIdentifier: ModelReadiness] = [:]
        for model in ModelIdentifier.allCases {
            if case .downloading = readiness[model]?.state {
                map[model] = readiness[model]
            } else {
                map[model] = WhisperModelLocator.readiness(for: model)
            }
        }
        readiness = map
    }

    func markDownloading(_ model: ModelIdentifier, progress: Double?) {
        readiness[model] = ModelReadiness(state: .downloading(progress))
        if let progress {
            bannerMessage = "Downloading \(model.displayName)… \(Int(progress * 100))%"
        } else {
            bannerMessage = "Downloading \(model.displayName)…"
        }
    }

    func markReady(_ model: ModelIdentifier) {
        readiness[model] = WhisperModelLocator.readiness(for: model)
        if readiness[model]?.state.isReady == true {
            bannerMessage = "\(model.displayName) ready"
            clearBannerLater()
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
