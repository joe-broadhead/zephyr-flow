#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    final class FlowProcessorTests: XCTestCase {
        let processor = FlowProcessor()

        private func validSyntheticStatistics() -> [FlowStyle: FlowStyleStats] {
            Dictionary(
                uniqueKeysWithValues: FlowStyle.allCases.map { style in
                    (
                        style,
                        FlowStyleStats(
                            style: style, totalCases: 100, criticalViolations: 0,
                            fallbackCount: 0, noopCount: 0, deterministicCount: 100)
                    )
                })
        }

        private func gate(_ stats: [FlowStyle: FlowStyleStats]) -> FlowReleaseGateResult {
            FlowReleaseGate.evaluate(corpusVersion: FlowFidelityCorpus.version, stats: stats, policy: .current)
        }

        func testReleaseGateRequiresEveryBudgetedStyleAndNonemptyEvidence() {
            let valid = validSyntheticStatistics()
            XCTAssertEqual(gate(valid), .pass, "synthetic evaluator fixture, not a measured corpus result")
            XCTAssertNotEqual(gate([:]), .pass)
            for style in FlowStyle.allCases {
                var missing = valid
                missing[style] = nil
                XCTAssertEqual(gate(missing), .fail(reason: "\(style.rawValue): missing statistics"))
                let empty = FlowStyleStats(
                    style: style, totalCases: 0, criticalViolations: 0,
                    fallbackCount: 0, noopCount: 0, deterministicCount: 0)
                XCTAssertEqual(empty.deterministicStability, 0)
                missing[style] = empty
                XCTAssertNotEqual(gate(missing), .pass)
            }
        }

        func testReleaseGateRejectsMalformedCountsAndStyleIdentity() {
            for bad in [
                FlowStyleStats(
                    style: .clean, totalCases: -1, criticalViolations: 0, fallbackCount: 0, noopCount: 0,
                    deterministicCount: 0),
                FlowStyleStats(
                    style: .clean, totalCases: 100, criticalViolations: -1, fallbackCount: 0, noopCount: 0,
                    deterministicCount: 100),
                FlowStyleStats(
                    style: .clean, totalCases: 100, criticalViolations: 0, fallbackCount: -1, noopCount: 0,
                    deterministicCount: 100),
                FlowStyleStats(
                    style: .clean, totalCases: 100, criticalViolations: 0, fallbackCount: 0, noopCount: -1,
                    deterministicCount: 100),
                FlowStyleStats(
                    style: .clean, totalCases: 100, criticalViolations: 0, fallbackCount: 0, noopCount: 0,
                    deterministicCount: 101),
                FlowStyleStats(
                    style: .raw, totalCases: 100, criticalViolations: 0, fallbackCount: 0, noopCount: 0,
                    deterministicCount: 100),
            ] {
                var stats = validSyntheticStatistics()
                stats[.clean] = bad
                XCTAssertEqual(gate(stats), .fail(reason: "clean: empty or invalid statistics"))
            }
        }

        func testReleaseGateDoesNotTreatInheritedCorpusAsComplete() {
            let measuredStyles = Set(FlowFidelityCorpus.cases.map(\.style))
            XCTAssertFalse(measuredStyles.contains(.raw), "existing corpus remains unchanged")
            let incomplete = validSyntheticStatistics().filter { measuredStyles.contains($0.key) }
            XCTAssertEqual(gate(incomplete), .fail(reason: "raw: missing statistics"))
            let emptyPolicy = FlowReleasePolicy(
                version: 1, baselineCommit: "synthetic", corpusVersion: FlowFidelityCorpus.version, budgets: [:])
            XCTAssertNotEqual(
                FlowReleaseGate.evaluate(corpusVersion: FlowFidelityCorpus.version, stats: [:], policy: emptyPolicy),
                .pass)
        }

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
