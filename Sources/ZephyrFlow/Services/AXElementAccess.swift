import ApplicationServices
import Foundation

/// Retains one AX handle and serializes its synchronous native operations.
/// The handle itself is not Sendable in the SDK. Callers must transfer all
/// access to this owner before dispatch; they never use the raw handle again.
/// This is a lifetime/serialization bridge, NOT target validation, permission
/// approval, an IPC timeout, or evidence that a remote app accepted a write.
final class AXElementAccess: @unchecked Sendable {
    private let element: AXUIElement
    private let lock = NSLock()

    init(_ element: AXUIElement) { self.element = element }

    func withElement<Value: Sendable>(_ operation: (AXUIElement) -> Value) -> Value {
        lock.withLock { operation(element) }
    }
}
