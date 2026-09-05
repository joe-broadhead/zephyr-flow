import AppKit
import ZephyrFlowCore

/// Synchronous native adapter used by the insertion actor. Tests use named
/// temporary pasteboards, never the user's general pasteboard. NSPasteboard
/// has no cross-process compare-and-swap: ownership checks are conservative
/// observations, not an atomic exclusion guarantee against another process.
enum PasteboardTransactionAdapter {
    static let markerType = NSPasteboard.PasteboardType("io.zephyr-flow.transaction")

    enum StageResult: Equatable, Sendable { case applied, refused, changed, restoreFailed }

    static func snapshot(from pasteboard: NSPasteboard, budget: PasteboardBudget = PasteboardBudget())
        -> PasteboardSnapshot?
    {
        let change = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= budget.maxItems else { return nil }
        // nil items with advertised types is not a known-empty pasteboard.
        guard !items.isEmpty || (pasteboard.types ?? []).isEmpty else { return nil }
        let result = PasteboardSnapshot.capture(
            itemTypes: items.map { $0.types.map(\.rawValue) }, changeCount: change, budget: budget
        ) {
            index, type in items[index].data(forType: NSPasteboard.PasteboardType(type))
        }
        guard pasteboard.changeCount == change else { return nil }
        return result
    }

    static func stage(_ text: String, transaction: inout PasteboardTransaction, on pasteboard: NSPasteboard)
        -> StageResult
    {
        guard transaction.state == .ready, !Task.isCancelled else { return .refused }
        let item = NSPasteboardItem()
        // Construct both representations BEFORE clearing the pasteboard.
        guard item.setString(text, forType: .string), item.setString(transaction.marker.value, forType: markerType)
        else {
            return .refused
        }
        guard pasteboard.changeCount == transaction.original.changeCount else { return .changed }
        let clearedGeneration = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            // If the failed write left exactly our clear generation, we still
            // own that empty value. Otherwise preserve the unknown newer value.
            guard pasteboard.changeCount == clearedGeneration else { return .restoreFailed }
            return restore(transaction.original, to: pasteboard, expectedChange: clearedGeneration)
                ? .refused : .restoreFailed
        }
        let writtenGeneration = pasteboard.changeCount
        guard pasteboard.string(forType: markerType) == transaction.marker.value,
            pasteboard.changeCount == writtenGeneration
        else { return .changed }
        transaction.applyTemporary(changeCount: writtenGeneration)
        return .applied
    }

    /// Shared by successful posting, event-creation failure, target change,
    /// permission loss and cancellation. No failure path may bypass ownership.
    static func finish(_ transaction: inout PasteboardTransaction, on pasteboard: NSPasteboard)
        -> PasteboardTransactionOutcome
    {
        if let outcome = transaction.outcome { return outcome }  // no duplicate restore write
        guard transaction.state == .temporaryApplied || transaction.state == .posted else {
            transaction.cancel()
            return transaction.outcome ?? .cancelled
        }
        let change = pasteboard.changeCount
        let markerMatches = pasteboard.string(forType: markerType) == transaction.marker.value
        let outcome = transaction.attemptRestore(
            currentChangeCount: pasteboard.changeCount,
            currentIsOurMarker: markerMatches && pasteboard.changeCount == change)
        guard outcome == .restored else { return outcome }
        if !restore(
            transaction.original, to: pasteboard, expectedChange: change, expectedMarker: transaction.marker.value)
        {
            transaction.markRestoreFailed()
        }
        return transaction.outcome ?? .restoreFailed
    }

    static func stillOwns(_ transaction: PasteboardTransaction, on pasteboard: NSPasteboard) -> Bool {
        let change = pasteboard.changeCount
        return change == transaction.tempChangeCount
            && pasteboard.string(forType: markerType) == transaction.marker.value
            && pasteboard.changeCount == change
    }

    private static func restore(
        _ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard,
        expectedChange: Int, expectedMarker: String? = nil
    ) -> Bool {
        var items: [NSPasteboardItem] = []
        for item in snapshot.items {
            let restored = NSPasteboardItem()
            for record in item.types {
                guard restored.setData(record.data, forType: .init(record.type)) else { return false }
            }
            items.append(restored)
        }
        guard pasteboard.changeCount == expectedChange else { return false }
        if let expectedMarker, pasteboard.string(forType: markerType) != expectedMarker { return false }
        guard pasteboard.changeCount == expectedChange else { return false }
        pasteboard.clearContents()
        if !items.isEmpty, !pasteboard.writeObjects(items) { return false }
        guard let actual = self.snapshot(from: pasteboard), actual.items.count == snapshot.items.count else {
            return false
        }
        for (expected, observed) in zip(snapshot.items, actual.items) {
            // Types may be enumerated in a different order by AppKit; ordered
            // items and the exact set of type/data representations must match.
            guard expected.types.count == observed.types.count,
                expected.types.allSatisfy({ observed.types.contains($0) })
            else { return false }
        }
        return true
    }
}
