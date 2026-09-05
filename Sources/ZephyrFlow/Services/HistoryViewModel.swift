import Combine
import Foundation
import ZephyrFlowCore

/// Review R4.1: single source of truth for history is the actor repository.
/// The Settings UI observes this async view model instead of the legacy
/// removed plaintext store, so production history is never written by two
/// incompatible stores to the same file.
@MainActor
final class HistoryViewModel: ObservableObject {
    static let shared = HistoryViewModel()

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private let repository: ActorHistoryRepository
    private let preparation: HistoryStoragePreparation
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()

    init(
        repository: ActorHistoryRepository = .shared,
        preparation: HistoryStoragePreparation = HistoryStoreRepository.preparation
    ) {
        self.repository = repository
        self.preparation = preparation
    }

    func start() {
        loadTask?.cancel()
        loadTask = Task { await reload() }
    }

    func reload() async {
        let id = UUID()
        generation = id
        isLoading = true
        defer { if generation == id { isLoading = false } }
        // UI access and session admission share key-before-load ordering.
        // Merely constructing this view model never opens the repository.
        let ready = await preparation.prepareForAccess()
        guard !Task.isCancelled, generation == id else { return }
        guard ready else {
            entries = []
            lastError = AppStrings.key("history.preparation.failed")
            return
        }
        let storage = await repository.entries()
        let writeError = await repository.lastWriteError
        guard !Task.isCancelled, generation == id else { return }
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
        if writeError != nil {
            lastError = AppStrings.key("history.write.failed")
        }
    }

    func delete(_ id: UUID) {
        Task {
            do {
                guard await preparation.prepareForAccess() else { throw HistoryRepositoryError.ioFailed }
                try await repository.delete(id)
                await reload()
            } catch {
                lastError = AppStrings.key("history.delete.failed")
            }
        }
    }

    func clear() {
        Task {
            do {
                guard await preparation.prepareForAccess() else { throw HistoryRepositoryError.ioFailed }
                try await repository.clear()
                await reload()
            } catch {
                lastError = AppStrings.key("history.clear.failed")
            }
        }
    }
}
