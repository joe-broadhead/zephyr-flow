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

        func testInsertionResultMessages() {
            XCTAssertNil(InsertionResult.inserted.userMessage)
            XCTAssertEqual(InsertionResult.copiedToClipboard.userMessage, "Copied to clipboard")
            XCTAssertTrue(InsertionResult.pasted.succeeded)
            XCTAssertFalse(InsertionResult.failed("x").succeeded)
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
