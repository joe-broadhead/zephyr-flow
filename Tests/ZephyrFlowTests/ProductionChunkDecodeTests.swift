#if canImport(XCTest)
    import WhisperKit
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private enum ChunkFixtureError: Error { case failed, timedOut }
    private actor ChunkRuntimeFixture: WhisperTranscriptionRuntime {
        struct Call: Sendable {
            let count: Int
            let first: Float?
            let last: Float?
            let timestamps: Bool
            let clip: Float
        }
        private(set) var calls: [Call] = []
        private let heldAt: Int?
        private let failAt: Int?
        private let missingAlignment: Bool
        private var pending: CheckedContinuation<Void, Never>?
        private var released = false
        init(heldAt: Int? = nil, failAt: Int? = nil, missingAlignment: Bool = false) {
            self.heldAt = heldAt
            self.failAt = failAt
            self.missingAlignment = missingAlignment
        }
        func transcribe(samples: [Float], options: DecodingOptions) async throws -> String { "synthetic partial" }
        func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript {
            calls.append(
                Call(
                    count: samples.count, first: samples.first, last: samples.last,
                    timestamps: options.wordTimestamps && !options.withoutTimestamps, clip: options.windowClipTime))
            if calls.count == heldAt && !released { await withCheckedContinuation { pending = $0 } }
            if calls.count == failAt { throw ChunkFixtureError.failed }
            let firstSecond = Int(samples.first ?? 0)
            var words: [ChunkWordTiming] = []
            for second in 0..<(samples.count / 16_000) {
                words.append(
                    .init(
                        text: " s\(firstSecond + second)",
                        samples: (second * 16_000 + 4_000)..<(second * 16_000 + 8_000)))
            }
            return .init(text: words.map(\.text).joined(), words: missingAlignment ? nil : words)
        }
        func release() {
            released = true
            pending?.resume()
            pending = nil
        }
        func awaitCalls(_ count: Int) async throws {
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while calls.count < count {
                guard ContinuousClock().now < deadline else { throw ChunkFixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    final class ProductionChunkDecodeTests: XCTestCase {
        private static func start(
            _ runtime: ChunkRuntimeFixture, seconds: Int = 65,
            budget: UInt64 = 120_000_000_000
        ) async throws -> WhisperKitEngine {
            let engine = WhisperKitEngine(runtimeFactory: { _ in runtime }, finalizationBudgetNanos: budget)
            try await engine.load(model: .whisperTiny, verifiedFolder: "/synthetic/tiny")
            try await engine.startStreaming(
                sessionID: SessionID(token: "chunk-fixture", sequence: 1, createdAtUptimeNanos: 1),
                localOnly: true, language: .enUS, onPartial: { _ in })
            for second in 0..<seconds { await engine.appendAudio([Float](repeating: Float(second), count: 16_000)) }
            return engine
        }

        func testCompleteAudioBeyondOldSixtySecondWindowUsesOrderedBoundedChunks() async throws {
            let runtime = ChunkRuntimeFixture()
            let engine = try await Self.start(runtime)
            let result = try await engine.stopAndFinalize()
            let calls = await runtime.calls
            XCTAssertEqual(calls.map(\.count), [480_000, 480_000, 144_000])
            XCTAssertEqual(calls.map(\.first), [0, 28, 56])
            XCTAssertEqual(calls.map(\.last), [29, 57, 64])
            XCTAssertTrue(calls.allSatisfy { $0.timestamps && $0.clip == 0 })
            XCTAssertEqual(result.text, (0..<65).map { "s\($0)" }.joined(separator: " "))
            XCTAssertEqual(result.completeness, .complete)
            XCTAssertEqual(result.frameAccounting?.decodedEngineSamples, 1_040_000)
            XCTAssertEqual(result.frameAccounting?.deliveredEngineSamples, 1_040_000)
            XCTAssertEqual(result.frameAccounting?.droppedSourceSamples, 0)
            XCTAssertTrue(result.isComplete)
            XCTAssertNotNil(result.startedAtUptimeNanos)
            XCTAssertNil(result.languageDetected, "requested language is not detection evidence")
        }

        func testTenMinuteMaximumKeepsPrefixAndAccountsExcess() async throws {
            let runtime = ChunkRuntimeFixture()
            let engine = try await Self.start(runtime, seconds: 600)
            await engine.appendAudio([600])
            let result = try await engine.stopAndFinalize()
            let calls = await runtime.calls
            XCTAssertEqual(calls.first?.first, 0)
            XCTAssertEqual(calls.last?.last, 599)
            XCTAssertTrue(calls.allSatisfy { $0.count <= 480_000 })
            XCTAssertEqual(result.text, (0..<600).map { "s\($0)" }.joined(separator: " "))
            XCTAssertEqual(result.frameAccounting?.capturedSourceSamples, 9_600_001)
            XCTAssertEqual(result.frameAccounting?.decodedEngineSamples, 9_600_000)
            XCTAssertEqual(result.frameAccounting?.droppedSourceSamples, 1)
            XCTAssertEqual(result.completeness, .truncated)
            XCTAssertFalse(result.isComplete)
            XCTAssertTrue(result.warnings.contains(.truncation))
        }

        func testMissingAlignmentRetainsEveryChunkHypothesisForReview() async throws {
            let runtime = ChunkRuntimeFixture(missingAlignment: true)
            let engine = try await Self.start(runtime)
            let result = try await engine.stopAndFinalize()
            XCTAssertEqual(result.completeness, .partial)
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.text.components(separatedBy: "\n\n").count, 3)
            XCTAssertTrue(result.text.contains("s0"))
            XCTAssertTrue(result.text.contains("s64"))
            XCTAssertEqual(result.frameAccounting?.decodedEngineSamples, 1_040_000)
            XCTAssertEqual(result.fallbackReason, "word alignment missing")
        }

        func testFailedMiddleChunkNeverClaimsFullRangeOrSkipsToLaterChunk() async throws {
            let runtime = ChunkRuntimeFixture(failAt: 2)
            let engine = try await Self.start(runtime)
            let result = try await engine.stopAndFinalize()
            let calls = await runtime.calls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(result.termination, .failed)
            XCTAssertEqual(result.completeness, .partial)
            XCTAssertEqual(result.frameAccounting?.decodedEngineSamples, 480_000)
            XCTAssertEqual(result.frameAccounting?.deliveredEngineSamples, 1_040_000)
            XCTAssertTrue(result.text.hasPrefix(" s0"))
            XCTAssertFalse(result.text.contains("s64"))
        }

        func testCancelDoesNotJoinHeldChunkOrPermitSubsequentChunksAndReuse() async throws {
            for cancelTask in [false, true] {
                let runtime = ChunkRuntimeFixture(heldAt: 1)
                let engine = try await Self.start(runtime)
                let final = Task { try await engine.stopAndFinalize() }
                addTeardownBlock {
                    final.cancel()
                    await runtime.release()
                    _ = try? await final.value
                }
                try await runtime.awaitCalls(1)
                if cancelTask { final.cancel() } else { await engine.cancel() }
                do {
                    _ = try await final.value
                    XCTFail("cancelled decode cannot publish")
                } catch is CancellationError {} catch { XCTFail("expected cancellation") }
                let busy = await engine.hasOutstandingDecode
                let quarantined = await engine.isQuarantined
                XCTAssertTrue(busy)
                XCTAssertTrue(quarantined)
                do {
                    try await engine.load(model: .whisperBase, verifiedFolder: "/synthetic/base")
                    XCTFail("held runtime cannot reload")
                } catch {}
                await runtime.release()
                let calls = await runtime.calls
                XCTAssertEqual(calls.count, 1)
            }
        }

        func testAbsoluteFinalizationDeadlineRetainsHeldNativeOwnership() async throws {
            let runtime = ChunkRuntimeFixture(heldAt: 1)
            let engine = try await Self.start(runtime, budget: 500_000_000)
            let final = Task { try await engine.stopAndFinalize() }
            addTeardownBlock {
                final.cancel()
                await runtime.release()
                _ = try? await final.value
            }
            try await runtime.awaitCalls(1)
            let result = try await final.value
            XCTAssertEqual(result.termination, .deadlineExceeded)
            XCTAssertEqual(result.completeness, .partial)
            XCTAssertEqual(result.frameAccounting?.decodedEngineSamples, 0)
            let busy = await engine.hasOutstandingDecode
            let quarantined = await engine.isQuarantined
            XCTAssertTrue(busy)
            XCTAssertTrue(quarantined)
            await runtime.release()
        }

        func testNativeAlignmentSnapshotRejectsInvalidTimestampsWithoutIntegerTraps() {
            for (start, end): (Float, Float) in [(.nan, 1), (0, .infinity), (-1, 1), (1, 0), (0, 31), (0, 0)] {
                let result = WhisperChunkAlignment.snapshot(
                    text: "x",
                    segments: [
                        .init(text: "x", words: [.init(word: "x", tokens: [1], start: start, end: end, probability: 1)])
                    ], sampleCount: 480_000)
                XCTAssertNil(result.words)
            }
            let valid = WhisperChunkAlignment.snapshot(
                text: "x",
                segments: [
                    .init(text: "x", words: [.init(word: "x", tokens: [1], start: 0.25, end: 0.5, probability: 1)])
                ], sampleCount: 16_000)
            XCTAssertEqual(valid.words, [.init(text: "x", samples: 4_000..<8_000)])
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
