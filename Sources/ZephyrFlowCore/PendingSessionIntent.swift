import Foundation

/// Round-5 review B2: an immutable, immediately-addressable session intent
/// allocated SYNCHRONOUSLY at the press edge (before the queued begin
/// operation starts). Release/cancel invalidate the intent even when the
/// begin operation has not yet run — closing the window where a quick
/// release queued behind a press could not preempt it.
///
/// All initiation paths (hotkey press, manual toggle, UI actions) must
/// create one of these first and pass it to the queued begin; the begin
/// checks `isCancelled` before and after every await.
public final class PendingSessionIntent: @unchecked Sendable {
    public let generation: UInt64
    public let pressTimestampNanos: UInt64
    public let requestedMode: String

    private let lock = NSLock()
    private var _cancelled = false

    public init(
        generation: UInt64,
        pressTimestampNanos: UInt64,
        requestedMode: String = "hotkey"
    ) {
        self.generation = generation
        self.pressTimestampNanos = pressTimestampNanos
        self.requestedMode = requestedMode
    }

    public var isCancelled: Bool { lock.withLock { _cancelled } }

    /// Invalidate the intent immediately (release/cancel at the press edge).
    public func cancel() {
        lock.withLock { _cancelled = true }
    }
}
