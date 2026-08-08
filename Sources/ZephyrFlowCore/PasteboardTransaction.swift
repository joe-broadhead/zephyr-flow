import Foundation

// JOE-2260: pasteboard insertion as a lossless, bounded transaction.
//
// Deterministic + AppKit-free: the app layer performs the real NSPasteboard
// reads/writes, but every decision (budget, equivalence, restore safety,
// controlled outcome) lives here so the full fixture matrix is unit-testable
// in the CLT core suite.

// MARK: - Snapshot model (ordered items, every type/data preserved)

/// One pasteboard item: every available type with its raw data payload.
/// Never flattened; round-trip is byte-for-byte.
public struct PasteboardTypeRecord: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct PasteboardItemSnapshot: Sendable, Equatable {
    public let types: [PasteboardTypeRecord]

    public init(types: [PasteboardTypeRecord]) {
        self.types = types
    }

    public var byteCount: Int { types.reduce(0) { $0 + $1.data.count } }
}

/// Full ordered snapshot of the pasteboard at transaction start.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let items: [PasteboardItemSnapshot]
    /// Whether the pasteboard was initially empty (restore = clear).
    public let isEmpty: Bool
    /// Pasteboard changeCount at snapshot time (for equivalence checks).
    public let changeCount: Int

    public init(items: [PasteboardItemSnapshot], changeCount: Int) {
        self.items = items
        self.isEmpty = items.isEmpty
        self.changeCount = changeCount
    }

    public var byteCount: Int { items.reduce(0) { $0 + $1.byteCount } }
    public var itemCount: Int { items.count }
}

// MARK: - Reviewed maximum budget

/// Reviewed snapshot budget. Exact preservation is only attempted within it;
/// overflow aborts the transaction with NO destructive clipboard mutation.
public struct PasteboardBudget: Sendable, Equatable {
    public let maxBytes: Int
    public let maxItems: Int
    public let maxTypesPerItem: Int

    public init(maxBytes: Int = 8_000_000, maxItems: Int = 64, maxTypesPerItem: Int = 256) {
        self.maxBytes = maxBytes
        self.maxItems = maxItems
        self.maxTypesPerItem = maxTypesPerItem
    }

    public func withinBudget(_ snapshot: PasteboardSnapshot) -> Bool {
        snapshot.byteCount <= maxBytes
            && snapshot.itemCount <= maxItems
            && snapshot.items.allSatisfy { $0.types.count <= maxTypesPerItem }
    }
}

// MARK: - Transaction state machine

public enum PasteboardTransactionState: String, Codable, Sendable, Equatable {
    case idle
    case ready  // snapshot taken; temporary not yet applied
    case temporaryApplied  // temp content + marker on the pasteboard
    case posted  // Cmd-V event posted
    case restored
    case notRestoredBecauseChanged
    case restoreFailed
    case overBudget
    case cancelled
    case abandonedDuringShutdown
}

/// Controlled outcome of a pasteboard transaction (content-free).
public enum PasteboardTransactionOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case restored
    case notRestoredBecauseChanged
    case restoreFailed
    case overBudget
    case cancelled
    case abandonedDuringShutdown
}

/// Unique transaction marker; the app writes it as a dedicated type on the
/// temporary content so restoration can detect "still ours" safely.
public struct PasteboardMarker: Sendable, Equatable {
    public let value: String
    public init(value: String = "io.zephyr-flow.insert.\(UUID().uuidString)") {
        self.value = value
    }
}

/// Lossless bounded pasteboard transaction (JOE-2260). Value type, single-shot
/// terminal outcomes, session-scoped.
public struct PasteboardTransaction: Sendable, Equatable {
    public let sessionID: SessionID
    public let original: PasteboardSnapshot
    public let marker: PasteboardMarker
    public let budget: PasteboardBudget
    public private(set) var state: PasteboardTransactionState
    public private(set) var tempChangeCount: Int?
    public private(set) var outcome: PasteboardTransactionOutcome?

    /// Begin the transaction: takes the snapshot and applies the budget.
    /// Returns nil (no transaction; NO clipboard mutation) when the snapshot
    /// exceeds the reviewed budget.
    public init?(
        sessionID: SessionID,
        original: PasteboardSnapshot,
        marker: PasteboardMarker = PasteboardMarker(),
        budget: PasteboardBudget = PasteboardBudget()
    ) {
        guard budget.withinBudget(original) else {
            self.sessionID = sessionID
            self.original = original
            self.marker = marker
            self.budget = budget
            self.state = .overBudget
            self.tempChangeCount = nil
            self.outcome = .overBudget
            return nil
        }
        self.sessionID = sessionID
        self.original = original
        self.marker = marker
        self.budget = budget
        self.state = .ready
        self.tempChangeCount = nil
        self.outcome = nil
    }

    /// Record the temporary content write (change count after writing).
    public mutating func applyTemporary(changeCount: Int) {
        guard state == .ready else { return }
        state = .temporaryApplied
        tempChangeCount = changeCount
    }

    /// Record that the Cmd-V event was posted.
    public mutating func markPosted() {
        guard state == .temporaryApplied else { return }
        state = .posted
    }

    /// Decide restoration safety. The app writes `original` back iff this
    /// returns `.restored`. If the user/target changed the pasteboard, the new
    /// value is preserved (`notRestoredBecauseChanged`) — never overwritten.
    public mutating func attemptRestore(
        currentChangeCount: Int,
        currentIsOurMarker: Bool
    ) -> PasteboardTransactionOutcome {
        if let outcome = outcome { return outcome }
        switch state {
        case .overBudget:
            outcome = .overBudget
            return outcome!
        case .cancelled:
            outcome = .cancelled
            return outcome!
        case .abandonedDuringShutdown:
            outcome = .abandonedDuringShutdown
            return outcome!
        case .idle, .ready:
            // Nothing posted yet; nothing to restore.
            state = .restored
            outcome = .restored
            return outcome!
        case .temporaryApplied, .posted:
            break
        case .restored, .notRestoredBecauseChanged, .restoreFailed:
            return outcome!
        }

        // Equivalence: unchanged since we wrote the temporary content, or the
        // marker type is still present => safe to restore exactly.
        if currentChangeCount == tempChangeCount || currentIsOurMarker {
            state = .restored
            outcome = .restored
            return outcome!
        }
        // User/target changed it — preserve their new value.
        state = .notRestoredBecauseChanged
        outcome = .notRestoredBecauseChanged
        return outcome!
    }

    /// Called when the actual restore write fails.
    public mutating func markRestoreFailed() {
        guard outcome == .restored else { return }
        state = .restoreFailed
        outcome = .restoreFailed
    }

    public mutating func cancel() {
        guard outcome == nil else { return }
        state = .cancelled
        outcome = .cancelled
    }

    public mutating func shutdown() {
        guard outcome == nil else { return }
        state = .abandonedDuringShutdown
        outcome = .abandonedDuringShutdown
    }
}

// MARK: - Sensitivity gate

/// Pasteboard transactions are only permitted for normal-sensitivity sessions
/// (JOE-2260 acceptance: secure/unknown cannot call this transaction).
public enum PasteboardTransactionPolicy {
    public static func allowed(sensitivity: SessionSensitivity) -> Bool {
        sensitivity.allowsAutomaticSideEffects
    }
}
