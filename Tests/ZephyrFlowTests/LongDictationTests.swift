#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    final class LongDictationTests: XCTestCase {
        func testBlockedBufferPreservesBeginningAndExactCrossBlockWindows() {
            var buffer = LongDictationAudioBuffer(maximumSamples: 10, blockSamples: 3)
            XCTAssertEqual(buffer.append([0, 1]), 2)
            XCTAssertEqual(buffer.append([2, 3, 4, 5, 6]), 5)
            XCTAssertEqual(buffer.samples(in: 1..<6), [1, 2, 3, 4, 5])
            XCTAssertEqual(buffer.recentSamples(maximum: 4), [3, 4, 5, 6])
            XCTAssertEqual(buffer.append([7, 8, 9, 10, 11]), 3)
            XCTAssertTrue(buffer.reachedLimit)
            XCTAssertEqual(buffer.rejectedSamples, 2)
            XCTAssertEqual(buffer.samples(in: 0..<10), Array(0..<10).map(Float.init))
            XCTAssertEqual(buffer.append([12]), 0)
            XCTAssertEqual(buffer.rejectedSamples, 3)
            XCTAssertNil(buffer.samples(in: -1..<1))
            XCTAssertNil(buffer.samples(in: 0..<11))
            XCTAssertEqual(buffer.samples(in: 10..<10), [])
            XCTAssertEqual(buffer.recentSamples(maximum: 0), [])
        }

        func testTenMinuteBoundaryDoesNotReplaceOldestSamples() {
            var buffer = LongDictationAudioBuffer()
            let block = [Float](repeating: 0.25, count: LongDictationPolicy.sampleRate)
            buffer.append([Float](repeating: 0.5, count: block.count))
            for _ in 1..<LongDictationPolicy.maximumSeconds { buffer.append(block) }
            XCTAssertEqual(buffer.sampleCount, 9_600_000)
            XCTAssertTrue(buffer.reachedLimit)
            XCTAssertEqual(buffer.append([0.75]), 0)
            XCTAssertEqual(buffer.rejectedSamples, 1)
            XCTAssertEqual(buffer.samples(in: 0..<1), [0.5])
            XCTAssertEqual(buffer.recentSamples(maximum: 1), [0.25])
        }

        func testChunkCoverageBelowAtAndAboveEveryWindowBoundary() throws {
            let maximum = LongDictationPolicy.maximumSamples
            let stride = LongDictationPolicy.chunkSamples - LongDictationPolicy.overlapSamples
            var counts: Set<Int> = [0, 1, maximum - 1, maximum]
            for boundary in Swift.stride(from: LongDictationPolicy.chunkSamples, through: maximum, by: stride) {
                for delta in -1...1 where boundary + delta <= maximum { counts.insert(boundary + delta) }
            }
            for count in counts {
                let plan = try XCTUnwrap(FinalDecodeChunkPlan.ranges(sampleCount: count))
                if count == 0 {
                    XCTAssertTrue(plan.isEmpty)
                    continue
                }
                XCTAssertEqual(plan.first?.lowerBound, 0)
                XCTAssertEqual(plan.last?.upperBound, count)
                for range in plan {
                    XCTAssertGreaterThan(range.count, 0)
                    XCTAssertLessThanOrEqual(range.count, 480_000)
                }
                for (left, right) in zip(plan, plan.dropFirst()) {
                    XCTAssertEqual(left.upperBound - right.lowerBound, 32_000)
                    XCTAssertGreaterThan(right.upperBound, left.upperBound)
                }
            }
            XCTAssertNil(FinalDecodeChunkPlan.ranges(sampleCount: -1))
            XCTAssertNil(FinalDecodeChunkPlan.ranges(sampleCount: maximum + 1))
        }

        private func chunks(secondWord: String = "boundary", shift: Int = 0) -> [DecodedAudioChunk] {
            [
                .init(
                    samples: 0..<480_000, text: "alpha boundary",
                    words: [
                        .init(text: "alpha", samples: 0..<1_000),
                        .init(text: " boundary", samples: 450_000..<455_000),
                    ]),
                .init(
                    samples: 448_000..<500_000, text: "\(secondWord) omega",
                    words: [
                        .init(text: secondWord, samples: (2_000 + shift)..<(7_000 + shift)),
                        .init(text: " omega", samples: 40_000..<41_000),
                    ]),
            ]
        }

        func testAlignedOverlapIsDeduplicatedExactlyOnce() {
            for shift in [-1_000, 0, 1_000] {
                XCTAssertEqual(
                    LongDictationStitcher.stitch(chunks(shift: shift), expectedSampleCount: 500_000),
                    .stitched("alpha boundary omega"))
            }
            XCTAssertEqual(
                LongDictationStitcher.stitch(
                    [
                        .init(samples: 0..<1, text: "  unchanged 👩🏽‍💻  ", words: nil)
                    ], expectedSampleCount: 1), .stitched("  unchanged 👩🏽‍💻  "))
        }

        func testMissingConflictingAndOutOfBoundsAlignmentPreservesAllHypotheses() {
            let left = chunks()[0]
            let candidates: [DecodedAudioChunk] = [
                .init(samples: 448_000..<500_000, text: "unaligned", words: nil),
                .init(samples: 448_000..<500_000, text: "mismatch", words: []),
                .init(samples: 448_000..<500_000, text: "x", words: [.init(text: "x", samples: 0..<60_000)]),
                chunks(secondWord: "different")[1],
                chunks(shift: 10_000)[1],
                .init(samples: 448_001..<500_000, text: "gap", words: nil),
            ]
            for candidate in candidates {
                let result = LongDictationStitcher.stitch([left, candidate], expectedSampleCount: 500_000)
                guard case .incomplete(let text, _) = result else {
                    XCTFail("unverified seam must be incomplete")
                    continue
                }
                XCTAssertEqual(text, left.text + "\n\n" + candidate.text)
            }
        }

        func testAmbiguousRepeatedWordsCannotBeDeduplicatedByTextAlone() {
            let words: [ChunkWordTiming] = [
                .init(text: "yes", samples: 450_000..<451_000),
                .init(text: " yes", samples: 452_000..<453_000),
            ]
            let result = LongDictationStitcher.stitch(
                [
                    .init(samples: 0..<480_000, text: "yes yes", words: words),
                    .init(
                        samples: 448_000..<500_000, text: "yes yes",
                        words: [
                            .init(text: "yes", samples: 2_000..<3_000), .init(text: " yes", samples: 4_000..<5_000),
                        ]),
                ], expectedSampleCount: 500_000)
            guard case .incomplete(let text, let reason) = result else {
                XCTFail("ambiguous repetition must be preserved")
                return
            }
            XCTAssertEqual(text, "yes yes\n\nyes yes")
            XCTAssertEqual(reason, "overlap alignment ambiguous")
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
