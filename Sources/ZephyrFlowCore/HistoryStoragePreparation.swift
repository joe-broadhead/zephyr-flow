import Foundation

/// Lazy encrypted-history initialization shared by admission and explicit
/// history UI access. Construction has no file or key-provider side effects.
/// A cancelled/timed-out waiter does not join a stuck native key/file call;
/// the single initialization worker remains owned until actual completion.
public actor HistoryStoragePreparation {
    private let repository: ActorHistoryRepository
    private let loadKey: @Sendable () async -> HistoryCryptoKey?
    private var worker: Task<Void, Never>?
    private var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
    public var isInitializing: Bool { worker != nil }

    public init(repository: ActorHistoryRepository, loadKey: @escaping @Sendable () async -> HistoryCryptoKey?) {
        self.repository = repository
        self.loadKey = loadKey
    }

    public func prepareForSession(saveHistory: Bool, timeoutNanos: UInt64 = 5_000_000_000) async -> Bool {
        // This guard is before ALL key/storage access and does not replace the
        // repository's actual state with a synthetic "disabled" readiness flag.
        guard saveHistory else { return !Task.isCancelled }
        return await prepareForAccess(timeoutNanos: timeoutNanos)
    }

    /// Used only for opted-in writes or the user's explicit history controls.
    public func prepareForAccess(timeoutNanos: UInt64 = 5_000_000_000) async -> Bool {
        guard !Task.isCancelled, timeoutNanos > 0 else { return false }
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        waiters[id] = continuation
        let timer = Task {
            do { try await Task.sleep(nanoseconds: timeoutNanos) } catch { return }
            continuation.finish()
        }
        if worker == nil {
            worker = Task {
                let ready = await self.initialize()
                self.complete(ready)
            }
        }
        let result = await withTaskCancellationHandler {
            for await ready in stream { return !Task.isCancelled && ready }
            return false
        } onCancel: {
            continuation.finish()
        }
        timer.cancel()
        waiters.removeValue(forKey: id)?.finish()
        return result
    }

    private func initialize() async -> Bool {
        if await repository.storageState == .readyEncrypted { return true }
        let key = await loadKey()
        await repository.configureEncryption(keyProvider: { key })
        do { try await repository.load() } catch { return false }
        // No plaintext/migration-pending/corruption/key-error state is accepted
        // as an encrypted write boundary. A later explicit retry can recover.
        return await repository.storageState == .readyEncrypted
    }

    private func complete(_ ready: Bool) {
        worker = nil
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.yield(ready)
            waiter.finish()
        }
    }
}
