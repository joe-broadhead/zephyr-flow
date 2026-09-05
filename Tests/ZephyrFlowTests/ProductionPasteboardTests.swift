#if canImport(XCTest)
    import AppKit
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    final class ProductionPasteboardTests: XCTestCase {
        private func board() -> NSPasteboard {
            let name = "zf-test-\(UUID())"
            let board = NSPasteboard(name: .init(name))
            board.clearContents()
            addTeardownBlock { NSPasteboard(name: .init(name)).releaseGlobally() }
            return board
        }

        private func transaction(_ board: NSPasteboard) throws -> PasteboardTransaction {
            let snapshot = try XCTUnwrap(PasteboardTransactionAdapter.snapshot(from: board))
            return try XCTUnwrap(
                PasteboardTransaction(
                    sessionID: SessionID(token: "synthetic", sequence: 1, createdAtUptimeNanos: 0), original: snapshot))
        }

        func testEmptyClipboardRestoresOnFailureBeforePostingWithoutDuplicateWrite() throws {
            let board = board()
            var tx = try transaction(board)
            XCTAssertTrue(tx.original.isEmpty)
            XCTAssertEqual(
                PasteboardTransactionAdapter.stage("synthetic transcript", transaction: &tx, on: board), .applied)
            XCTAssertTrue(PasteboardTransactionAdapter.stillOwns(tx, on: board))
            // No markPosted call: same cleanup used when event creation or
            // target revalidation fails. No CGEvent is posted in this suite.
            XCTAssertEqual(PasteboardTransactionAdapter.finish(&tx, on: board), .restored)
            XCTAssertTrue(try XCTUnwrap(PasteboardTransactionAdapter.snapshot(from: board)).isEmpty)
            let change = board.changeCount
            XCTAssertEqual(PasteboardTransactionAdapter.finish(&tx, on: board), .restored)
            XCTAssertEqual(board.changeCount, change)
        }

        func testRichMultiItemRawRepresentationsRoundTripAfterPostedState() throws {
            let board = board()
            let first = NSPasteboardItem()
            XCTAssertTrue(first.setString("synthetic original", forType: .string))
            XCTAssertTrue(first.setData(Data("{\\rtf1 synthetic}".utf8), forType: .rtf))
            let second = NSPasteboardItem()
            XCTAssertTrue(second.setString("file:///synthetic/example.txt", forType: .fileURL))
            // Synthetic bytes only: type/data preservation, not image decoding.
            XCTAssertTrue(second.setData(Data([0, 1, 2, 3]), forType: .png))
            XCTAssertTrue(board.writeObjects([first, second]))
            var tx = try transaction(board)
            XCTAssertEqual(
                PasteboardTransactionAdapter.stage("synthetic temporary", transaction: &tx, on: board), .applied)
            tx.markPosted()  // simulated state; no event sent
            XCTAssertEqual(PasteboardTransactionAdapter.finish(&tx, on: board), .restored)
            let restored = try XCTUnwrap(PasteboardTransactionAdapter.snapshot(from: board))
            XCTAssertEqual(restored.items.count, tx.original.items.count)
            for (actual, expected) in zip(restored.items, tx.original.items) {
                XCTAssertEqual(actual.types.count, expected.types.count)
                XCTAssertTrue(expected.types.allSatisfy { actual.types.contains($0) })
            }
        }

        func testNewClipboardGenerationIsPreservedEvenIfItCarriesOurMarker() throws {
            let board = board()
            var tx = try transaction(board)
            XCTAssertEqual(
                PasteboardTransactionAdapter.stage("synthetic temporary", transaction: &tx, on: board), .applied)
            let foreign = NSPasteboardItem()
            XCTAssertTrue(foreign.setString("synthetic newer value", forType: .string))
            XCTAssertTrue(foreign.setString(tx.marker.value, forType: PasteboardTransactionAdapter.markerType))
            board.clearContents()
            XCTAssertTrue(board.writeObjects([foreign]))
            let change = board.changeCount
            XCTAssertFalse(PasteboardTransactionAdapter.stillOwns(tx, on: board))
            XCTAssertEqual(PasteboardTransactionAdapter.finish(&tx, on: board), .notRestoredBecauseChanged)
            XCTAssertEqual(board.changeCount, change)
            XCTAssertEqual(board.string(forType: .string), "synthetic newer value")
        }

        func testChangedSnapshotAndUnstagedFinishCannotMutateClipboard() throws {
            let board = board()
            var tx = try transaction(board)
            board.clearContents()
            XCTAssertTrue(board.setString("synthetic newer", forType: .string))
            let change = board.changeCount
            XCTAssertEqual(
                PasteboardTransactionAdapter.stage("synthetic temporary", transaction: &tx, on: board), .changed)
            XCTAssertEqual(PasteboardTransactionAdapter.finish(&tx, on: board), .cancelled)
            XCTAssertEqual(board.changeCount, change)
        }

        func testSnapshotRejectsUnreadableOrOverBudgetDataWithoutSkippingRepresentations() {
            var reads = 0
            let limited = PasteboardBudget(maxBytes: 2, maxItems: 1, maxTypesPerItem: 2)
            XCTAssertNil(
                PasteboardSnapshot.capture(itemTypes: [["a", "b", "c"]], changeCount: 0, budget: limited) { _, _ in
                    reads += 1
                    return Data()
                })
            XCTAssertEqual(reads, 0)
            XCTAssertNil(
                PasteboardSnapshot.capture(itemTypes: [["a", "b"]], changeCount: 0) { _, type in
                    reads += 1
                    return type == "a" ? nil : Data()
                })
            XCTAssertEqual(reads, 1)
            XCTAssertNil(
                PasteboardSnapshot.capture(itemTypes: [["a", "b"]], changeCount: 0, budget: limited) { _, _ in
                    reads += 1
                    return Data(repeating: 1, count: 3)
                })
            XCTAssertEqual(reads, 2, "stop reading when the first representation exceeds the retained budget")
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
