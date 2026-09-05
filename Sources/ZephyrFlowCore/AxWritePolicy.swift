import Foundation

// JOE-2270: selection-safe, bounded, verifiable AX writes.
//
// All logic here is deterministic and AppKit-free so the fake-element matrix,
// Unicode selection tests and bounded-call tests run in the CLT core suite.
// The app layer (InsertionService) consults these policies immediately before
// every write and routes AX calls through the bounded runner.

// MARK: - AX error mapping (controlled outcomes/metrics, content-free)

/// Content-free controlled classification of an AX error code.
public enum AxErrorOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case ok
    case failed
    case notEditable  // attributeUnsupported / notImplemented on value
    case notSupported
    case axDisabled  // apiDisabled / not trusted
    case timeout  // cannotComplete / hung target
    case illegalArgument
    case unknown

    /// Maps an AXError-style raw integer to a controlled outcome. The app
    /// layer passes `error.rawValue` so Core stays AppKit-free.
    public static func map(rawValue: Int32) -> AxErrorOutcome {
        switch rawValue {
        case 0: return .ok
        case -25200: return .failed
        case -25201: return .illegalArgument
        case -25202, -25203: return .failed
        case -25204: return .timeout
        case -25205: return .notEditable
        case -25206: return .notSupported
        case -25207: return .notEditable
        case -25208: return .notSupported
        case -25210: return .axDisabled
        default: return .unknown
        }
    }
}

// MARK: - Selection model (UTF-16 safe)

/// A validated AX selection range. Positions are UTF-16 code units, matching
/// NSString/AX selected-text-range semantics. Never carries field contents.
public struct AxSelection: Sendable, Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    /// Bounds check against a UTF-16 length; malformed ranges are rejected
    /// (they must never reach a write).
    public func isValid(utf16Length: Int) -> Bool {
        utf16Length >= 0 && location <= utf16Length && location + length <= utf16Length
    }

    /// Insertion caret for a validated range (used after verified mutation).
    public func caretAfter(replacingWith replacementUTF16Length: Int) -> Int {
        location + replacementUTF16Length
    }
}

// MARK: - Capability + plan

/// Write capability of the focused element (content-free).
public struct AxElementCapability: Sendable, Equatable {
    public let settable: Bool
    public let editable: Bool
    public let enabled: Bool
    public let isSecure: Bool
    public let role: String?
    public let subrole: String?

    public init(
        settable: Bool, editable: Bool, enabled: Bool, isSecure: Bool,
        role: String?, subrole: String?
    ) {
        self.settable = settable
        self.editable = editable
        self.enabled = enabled
        self.isSecure = isSecure
        self.role = role
        self.subrole = subrole
    }

    public var writable: Bool { settable && editable && enabled && !isSecure }
}

/// Versioned, explicit qualification for range/value mutation. The default
/// adapter list is EMPTY: no app is qualified for whole-value rewriting until
/// evidence-backed records are added (JOE-2271 registry). This removes the
/// generic whole-value fallback per the JOE-2270 contract.
public struct AxValueAdapterQualification: Sendable, Equatable {
    /// Capability key, e.g. "ax.value.replace.v1".
    public let capabilityKey: String
    /// Exact bundle id the qualification applies to.
    public let bundleID: String
    /// Roles permitted (nil = any text role).
    public let roles: Set<String>?
    /// Minimum macOS version (e.g. "14.0"), when known.
    public let macOSMin: String?
    /// Evidence reference (doc path or report id) — never field content.
    public let evidenceReference: String

    public init(
        capabilityKey: String, bundleID: String, roles: Set<String>?,
        macOSMin: String?, evidenceReference: String
    ) {
        self.capabilityKey = capabilityKey
        self.bundleID = bundleID
        self.roles = roles
        self.macOSMin = macOSMin
        self.evidenceReference = evidenceReference
    }
}

/// Registry of explicitly qualified value/range adapters (versioned, empty by
/// default; unit-testable without AppKit). Adding entries is a code change and
/// is visible in tests/docs (JOE-2271 builds the full registry).
public struct AxValueAdapterRegistry: Sendable {
    public private(set) var qualifications: [AxValueAdapterQualification]

    public init(qualifications: [AxValueAdapterQualification] = []) {
        self.qualifications = qualifications
    }

    public static let `default` = AxValueAdapterRegistry(qualifications: [])

    public func qualification(forBundle bundleID: String?, role: String?) -> AxValueAdapterQualification? {
        guard let bundleID else { return nil }
        return qualifications.first { q in
            q.bundleID == bundleID
                && (q.roles == nil || role.map { q.roles!.contains($0) } ?? false)
        }
    }

    /// Registry hygiene: no duplicate bundle+role entries.
    public var hasOverlaps: Bool {
        var seen = Set<String>()
        for q in qualifications {
            let key = q.bundleID + "|" + (q.roles?.sorted().joined(separator: ",") ?? "*")
            if seen.contains(key) { return true }
            seen.insert(key)
        }
        return false
    }
}

/// Why a write plan was rejected (content-free).
public enum AxWriteRejection: String, Codable, CaseIterable, Sendable, Equatable {
    case notSettable
    case readOnly
    case secure
    case disabled
    case malformedSelection
    case outOfRange
    case wholeValueNotQualified
    case noSelection
}

/// The write plan for a single AX write (decided before any side effect).
public enum AxWritePlan: Sendable, Equatable {
    /// Preferred: replace AXSelectedText (in-place, caret-preserving).
    case selectedTextReplacement
    /// Range/value mutation inside an explicitly qualified adapter only.
    case rangeMutation(range: AxSelection, replacementUTF16Length: Int)
    case rejected(reason: AxWriteRejection)

    public var isWrite: Bool {
        switch self {
        case .selectedTextReplacement, .rangeMutation: return true
        case .rejected: return false
        }
    }
}

/// Deterministic write policy: decide the plan immediately before every write.
public enum AxWritePolicy {
    /// - Parameters:
    ///   - capability: current element capability (freshly resolved).
    ///   - selection: current selected range, when available.
    ///   - currentUTF16Length: length of the current value, when available.
    ///   - text: the payload to insert (length only is used).
    ///   - qualification: explicit adapter qualification (nil => whole-value
    ///     range mutation is rejected).
    public static func plan(
        capability: AxElementCapability,
        selection: AxSelection?,
        currentUTF16Length: Int?,
        text: String,
        qualification: AxValueAdapterQualification?
    ) -> AxWritePlan {
        // Hard gates first: no write to non-settable/read-only/secure/disabled.
        guard capability.writable else {
            if capability.isSecure { return .rejected(reason: .secure) }
            if !capability.settable || !capability.editable { return .rejected(reason: .notSettable) }
            if !capability.enabled { return .rejected(reason: .disabled) }
            return .rejected(reason: .notSettable)
        }

        // Preferred path: selected-text replacement when a valid selection
        // exists and the range is in bounds.
        if let selection {
            if let utf16 = currentUTF16Length, !selection.isValid(utf16Length: utf16) {
                return .rejected(reason: .outOfRange)
            }
            return .selectedTextReplacement
        }

        // Range/value mutation requires explicit adapter qualification.
        guard let qualification else {
            return .rejected(reason: .wholeValueNotQualified)
        }
        // The qualification is what permits the range path (its capability key
        // is surfaced in diagnostics/UI, never field content).
        let _ = qualification.capabilityKey
        guard let utf16 = currentUTF16Length else {
            return .rejected(reason: .malformedSelection)
        }
        // With no selection, mutate at the end (append) — still requires the
        // qualified adapter; never a blind whole-value rewrite.
        let append = AxSelection(location: utf16, length: 0)
        guard append.isValid(utf16Length: utf16) else {
            return .rejected(reason: .outOfRange)
        }
        return .rangeMutation(range: append, replacementUTF16Length: (text as NSString).length)
    }
}

// MARK: - Bounded AX call isolation

/// Result of a bounded AX call. Late results after the deadline are dropped.
public enum AxBoundedResult<Value: Sendable>: Sendable {
    case completed(Value)
    case deadlineExceeded(elapsedNanos: UInt64)
    case busy
    case cancelled(operationMayHaveStarted: Bool)

    public var value: Value? {
        if case .completed(let v) = self { return v }
        return nil
    }
}

/// One outstanding native operation per lane. Timeout/cancellation closes the
/// caller's waiter, not native ownership. The lane is released only when the
/// worker exits, so a stuck call cannot accumulate retries/verification threads.
/// The shared lane is used by all production AX writes and their verification.
public final class AxOperationLane: @unchecked Sendable {
    public static let shared = AxOperationLane()
    private let lock = NSLock()
    private var owner: UUID?
    fileprivate let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    public convenience init() { self.init(schedule: { Thread.detachNewThread($0) }) }
    /// Internal test seam: hold a worker before admission without real AX IPC.
    init(schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) { self.schedule = schedule }
    public var hasOutstandingWork: Bool { lock.withLock { owner != nil } }
    fileprivate func acquire() -> UUID? {
        lock.withLock {
            guard owner == nil else { return nil }
            let id = UUID()
            owner = id
            return id
        }
    }
    fileprivate func complete(_ id: UUID) {
        lock.withLock { if owner == id { owner = nil } }
    }
}

/// Dedicated-thread native execution with a cancellable, deadline-bounded
/// waiter. Scheduling is not hard real time. An already-started synchronous
/// mutation can still apply after timeout/cancellation; never retry blindly.
/// This runner does not bound AX calls made outside it or enforce target leases.
public enum AxBoundedRunner {
    /// - Parameters:
    ///   - deadlineNanosAhead: caller budget for this single call.
    ///   - startedAtNanos: continuous-clock start instant.
    ///   - nowNanos: clock read (deterministic in tests).
    ///   - operation: the AX call.
    public static func run<Value: Sendable>(
        deadlineNanosAhead: UInt64,
        startedAtNanos: UInt64,
        nowNanos: @escaping @Sendable () -> UInt64,
        lane: AxOperationLane = .shared,
        operation: @escaping @Sendable () -> Value
    ) async -> AxBoundedResult<Value> {
        let elapsedAtStart = elapsed(now: nowNanos(), start: startedAtNanos)
        if Task.isCancelled { return .cancelled(operationMayHaveStarted: false) }
        if elapsedAtStart >= deadlineNanosAhead {
            return .deadlineExceeded(elapsedNanos: elapsedAtStart)
        }
        guard let id = lane.acquire() else { return .busy }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(clamping: deadlineNanosAhead - elapsedAtStart)))
        let (stream, completion) = AsyncStream.makeStream(
            of: AxBoundedResult<Value>.self, bufferingPolicy: .bufferingNewest(1))
        let flight = AxCallCompletion(completion: completion)
        let result: AxBoundedResult<Value>? = await withTaskCancellationHandler {
            let timer = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                flight.finish(.deadlineExceeded(elapsedNanos: elapsed(now: nowNanos(), start: startedAtNanos)))
            }
            defer {
                timer.cancel()
                completion.finish()
            }
            lane.schedule {
                // Recheck at worker admission, not just before scheduling.
                // This is not an atomic deadline fence around an OS mutation.
                let age = elapsed(now: nowNanos(), start: startedAtNanos)
                guard age < deadlineNanosAhead, clock.now < deadline else {
                    lane.complete(id)
                    flight.finish(.deadlineExceeded(elapsedNanos: age))
                    return
                }
                guard flight.begin() else {
                    lane.complete(id)
                    return
                }
                let value = operation()
                lane.complete(id)  // actual native completion, never caller timeout
                let ageAtEnd = elapsed(now: nowNanos(), start: startedAtNanos)
                if ageAtEnd >= deadlineNanosAhead || clock.now >= deadline {
                    flight.finish(.deadlineExceeded(elapsedNanos: ageAtEnd))
                } else {
                    flight.finish(.completed(value))
                }
            }
            for await value in stream { return value }
            return nil
        } onCancel: {
            flight.cancel()
        }
        if Task.isCancelled { return .cancelled(operationMayHaveStarted: flight.mayHaveStarted) }
        return result ?? .deadlineExceeded(elapsedNanos: elapsed(now: nowNanos(), start: startedAtNanos))
    }

    private static func elapsed(now: UInt64, start: UInt64) -> UInt64 { now >= start ? now - start : .max }
}

/// The lock serializes worker admission with cancellation/timeout publication.
/// No native call or user closure executes while it is held. The native worker
/// retains this bounded state until actual completion even if its waiter left.
private final class AxCallCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private let completion: AsyncStream<AxBoundedResult<Value>>.Continuation
    init(completion: AsyncStream<AxBoundedResult<Value>>.Continuation) { self.completion = completion }
    var mayHaveStarted: Bool { lock.withLock { started } }
    func begin() -> Bool {
        lock.withLock {
            guard !finished, !started else { return false }
            started = true
            return true
        }
    }
    func cancel() {
        let startedAtCancellation: Bool? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return started
        }
        if let startedAtCancellation {
            completion.yield(.cancelled(operationMayHaveStarted: startedAtCancellation))
            completion.finish()
        }
    }
    func finish(_ result: AxBoundedResult<Value>) {
        let publish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if publish {
            completion.yield(result)
            completion.finish()
        }
    }
}
