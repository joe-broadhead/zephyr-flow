#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    final class FlowProcessorTests: XCTestCase {
        let processor = FlowProcessor()

        func testRawPassthrough() async {
            let input = "  um hello world  "
            let out = await processor.process(input, style: .raw)
            XCTAssertEqual(out, "um hello world")
        }

        func testCleanRemovesFillers() async {
            let input = "um I think uh we should, you know, ship it"
            let out = await processor.process(input, style: .clean)
            XCTAssertFalse(out.lowercased().contains("um"))
            XCTAssertFalse(out.lowercased().contains("uh"))
            XCTAssertFalse(out.lowercased().contains("you know"))
            XCTAssertTrue(out.lowercased().contains("ship"))
        }

        func testCleanCapitalizes() async {
            let out = await processor.process("hello there everyone", style: .clean)
            XCTAssertTrue(out.hasPrefix("H"))
        }

        func testBulletsFromSentences() async {
            let input = "Buy milk. Call mom. Ship the release."
            let out = await processor.process(input, style: .bullets)
            let lines = out.split(separator: "\n")
            XCTAssertGreaterThanOrEqual(lines.count, 2)
            XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("•") })
        }

        func testProfessionalExpandsContractions() async {
            let out = await processor.process("I can't ship this yet", style: .professional)
            XCTAssertTrue(out.lowercased().contains("cannot"))
            XCTAssertFalse(out.contains("can't"))
        }

        func testEmptyInput() async {
            let out = await processor.process("   ", style: .clean)
            XCTAssertEqual(out, "")
        }

        func testSummaryKeepsEssence() async {
            let input =
                "We need to ship today. The build is green. Stakeholders are waiting for the demo this afternoon."
            let out = await processor.process(input, style: .summary)
            XCTAssertFalse(out.isEmpty)
            XCTAssertTrue(out.count <= input.count)
        }
    }

    final class ModelsTests: XCTestCase {
        func testDefaultSettingsArePrivate() {
            let s = AppSettings.default
            XCTAssertTrue(s.localOnlyMode)
            XCTAssertEqual(s.preferredModel, .whisperTiny)
            XCTAssertEqual(s.hotkey.specialKey, .fn)
        }

        func testSettingsRoundTrip() throws {
            let original = AppSettings.default
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(original, decoded)
        }

        func testInsertionOutcomeDistinguishesVerifiedWriteFromPostedEvent() {
            let verified = InsertionOutcome.verifiedInserted(
                strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: [])
            XCTAssertTrue(verified.isVerifiedSuccess)
            XCTAssertTrue(verified.isCompletedAction)
            XCTAssertTrue(verified.permitsGreenSuccessUI)
            XCTAssertTrue(verified.permitsHistoryRetention)
            XCTAssertEqual(verified.userFacingMessage, "Inserted")

            let posted = InsertionOutcome.eventPostedUnverified(
                strategy: .clipboardPaste, warnings: [.noPostWriteVerification])
            XCTAssertTrue(posted.isCompletedAction)
            XCTAssertFalse(posted.isVerifiedSuccess)
            XCTAssertFalse(posted.permitsGreenSuccessUI)
            XCTAssertFalse(posted.permitsHistoryRetention)
            XCTAssertEqual(posted.userFacingMessage, "Paste sent — verify destination")
        }

        func testInsertionOutcomeDistinguishesExplicitCopyFromAutomaticCopy() {
            let explicit = InsertionOutcome.explicitlyCopiedByUser
            XCTAssertTrue(explicit.isCompletedAction)
            XCTAssertFalse(explicit.isVerifiedSuccess, "copy is not evidence of target insertion")
            XCTAssertTrue(explicit.permitsGreenSuccessUI)
            XCTAssertEqual(explicit.userFacingMessage, "Copied to clipboard")

            let automatic = InsertionOutcome.automaticCopy
            XCTAssertTrue(automatic.isCompletedAction)
            for outcome in [automatic, .automaticCopyBlocked] {
                XCTAssertFalse(outcome.isVerifiedSuccess)
                XCTAssertFalse(outcome.permitsGreenSuccessUI)
                XCTAssertFalse(outcome.permitsHistoryRetention)
                XCTAssertFalse(outcome.permitsAutomaticPanelDismissal)
                XCTAssertTrue(outcome.isUncertain)
            }
            XCTAssertFalse(InsertionOutcome.automaticCopyBlocked.isCompletedAction)
            XCTAssertNotEqual(automatic.userFacingMessage, explicit.userFacingMessage)
        }

        func testInsertionUncertaintyAndFailureCannotClaimSuccess() {
            let outcomes: [InsertionOutcome] = [
                .targetChanged, .targetGone, .targetUnknown, .secureTarget, .notEditable,
                .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
                .deadlineExceeded, .writeMayHaveApplied, .cancelled, .failed("synthetic failure"),
            ]
            for outcome in outcomes {
                XCTAssertFalse(outcome.isVerifiedSuccess)
                XCTAssertFalse(outcome.isCompletedAction)
                XCTAssertFalse(outcome.permitsGreenSuccessUI)
                XCTAssertFalse(outcome.permitsHistoryRetention)
                XCTAssertFalse(outcome.permitsAutomaticPanelDismissal)
            }
            XCTAssertTrue(InsertionOutcome.writeMayHaveApplied.isUncertain)
            XCTAssertEqual(
                InsertionOutcome.writeMayHaveApplied.userFacingMessage,
                "The write may have applied — verify the destination before retrying")
        }

        func testHistoryEntryIdentity() {
            let a = HistoryEntry(originalText: "a", finalText: "A", duration: 1, modelUsed: "t")
            let b = HistoryEntry(originalText: "a", finalText: "A", duration: 1, modelUsed: "t")
            XCTAssertNotEqual(a.id, b.id)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
