#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    final class SpeechFinalizationSignalTests: XCTestCase {
        func testTerminalBeforeWaitIsBufferedAndNeverReplaced() async throws {
            for event in [
                SpeechFinalEvent.finalResult(hasText: true), .finalResult(hasText: false),
                .terminalError(code: 1, friendly: "synthetic"), .cancelled, .deadlineExceeded,
            ] {
                let signal = SpeechFinalizationSignal()
                XCTAssertTrue(signal.complete(event))
                XCTAssertFalse(signal.complete(.cancelled))
                let result = try await signal.wait(deadlineNanosAhead: 1_000_000_000)
                XCTAssertEqual(result, event)
                do {
                    _ = try await signal.wait(deadlineNanosAhead: 0)
                    XCTFail("only one waiter is allowed")
                } catch SpeechFinalizationSignal.WaitError.alreadyWaited {} catch { XCTFail("unexpected error") }
            }
        }

        func testDeadlineCompletesWithoutJoiningMissingNativeCallback() async throws {
            let signal = SpeechFinalizationSignal()
            let result = try await signal.wait(deadlineNanosAhead: 1_000_000)
            XCTAssertEqual(result, .deadlineExceeded)
            XCTAssertFalse(signal.complete(.finalResult(hasText: true)))
        }

        func testCallerCancellationCannotCompleteAnotherRun() async throws {
            let old = SpeechFinalizationSignal()
            let current = SpeechFinalizationSignal()
            let waiter = Task { try await old.wait(deadlineNanosAhead: 60_000_000_000) }
            waiter.cancel()
            do {
                _ = try await waiter.value
                XCTFail("cancelled task cannot publish final text")
            } catch is CancellationError {} catch { XCTFail("unexpected error") }
            XCTAssertFalse(old.complete(.finalResult(hasText: true)))
            XCTAssertTrue(current.complete(.finalResult(hasText: true)))
            let result = try await current.wait(deadlineNanosAhead: 1_000_000_000)
            XCTAssertEqual(result, .finalResult(hasText: true))
        }

        func testConcurrentCompletionHasOneWinner() async throws {
            let signal = SpeechFinalizationSignal()
            let winners = await withTaskGroup(of: Int.self) { group in
                for index in 0..<64 {
                    group.addTask {
                        signal.complete(index.isMultiple(of: 2) ? .cancelled : .finalResult(hasText: true)) ? 1 : 0
                    }
                }
                var count = 0
                for await value in group { count += value }
                return count
            }
            XCTAssertEqual(winners, 1)
            let result = try await signal.wait(deadlineNanosAhead: 1_000_000_000)
            XCTAssertTrue(result == .cancelled || result == .finalResult(hasText: true))
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
