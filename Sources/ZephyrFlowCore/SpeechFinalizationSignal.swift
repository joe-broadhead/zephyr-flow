import Foundation

/// One signal per recognition run. First completion wins; no timer or caller
/// reaches through an actor to a mutable continuation belonging to a later run.
/// The lock protects only admission/completion, never an await or native call.
public final class SpeechFinalizationSignal: @unchecked Sendable {
    public enum WaitError: Error { case alreadyWaited }
    private let lock = NSLock()
    private let stream: AsyncStream<SpeechFinalEvent>
    private let continuation: AsyncStream<SpeechFinalEvent>.Continuation
    private var completed = false
    private var waited = false

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: SpeechFinalEvent.self, bufferingPolicy: .bufferingNewest(1))
    }

    @discardableResult
    public func complete(_ event: SpeechFinalEvent) -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            continuation.yield(event)
            continuation.finish()
            return true
        }
    }

    /// Consumed once. A terminal callback before registration remains buffered.
    /// Cancelling the waiter releases it, not any native framework resources.
    public func wait(deadlineNanosAhead: UInt64) async throws -> SpeechFinalEvent {
        let admitted = lock.withLock {
            guard !waited else { return false }
            waited = true
            return true
        }
        guard admitted else { throw WaitError.alreadyWaited }
        let timer = Task {
            do { try await Task.sleep(nanoseconds: deadlineNanosAhead) } catch { return }
            complete(.deadlineExceeded)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for await event in stream {
                try Task.checkCancellation()
                return event
            }
            throw CancellationError()
        } onCancel: {
            self.complete(.cancelled)
        }
    }
}
