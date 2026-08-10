import Combine
import Foundation
import ZephyrFlowCore

/// Review R4.1: single source of truth for history is the actor repository.
/// The Settings UI observes this async view model instead of the legacy
/// plaintext HistoryStore, so production history is never written by two
/// incompatible stores to the same file.
@MainActor
final class HistoryViewModel: ObservableObject {
    static let shared = HistoryViewModel()

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private init() {}

    func start() {
        Task {
            // Review R7/B8: ensure the repository is loaded (not just reading
            // in-memory entries); surface load errors. reload() must NOT
            // clear a load error we just set.
            if !(await ActorHistoryRepository.shared.isInitialized) {
                do {
                    try await ActorHistoryRepository.shared.load()
                    await reload()
                } catch {
                    lastError = "Could not load history: \(error.localizedDescription)"
                }
            } else {
                await reload()
            }
        }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let storage = await ActorHistoryRepository.shared.entries()
        entries = storage.map { entry in
            HistoryEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                originalText: entry.text,
                finalText: entry.text,
                duration: entry.duration,
                modelUsed: entry.modelUsed)
        }
        lastError = nil
        // Surface any silent write failure from add() (review R4.1).
        if let writeError = await ActorHistoryRepository.shared.lastWriteError {
            lastError = "History write issue: \(writeError)"
        }
    }

    func delete(_ id: UUID) {
        Task {
            do {
                try await ActorHistoryRepository.shared.delete(id)
                await reload()
            } catch {
                lastError = "Could not delete entry: \(error.localizedDescription)"
            }
        }
    }

    func clear() {
        Task {
            do {
                try await ActorHistoryRepository.shared.clear()
                await reload()
            } catch {
                lastError = "Could not clear history: \(error.localizedDescription)"
            }
        }
    }
}
