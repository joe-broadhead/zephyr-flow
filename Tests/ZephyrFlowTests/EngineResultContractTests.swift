#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    final class EngineResultContractTests: XCTestCase {
        private static func result(
            text: String = "synthetic final", completeness: EngineResultCompleteness = .complete,
            accounting: EngineFrameAccounting?, termination: EngineResultTermination = .completed
        ) -> EngineResult {
            EngineResult(
                text: text, completeness: completeness, frameAccounting: accounting,
                engine: .init(kind: .whisper, modelName: "synthetic", modelVersion: nil, modelDigest: nil),
                languageRequested: "en-US", languageDetected: nil, confidence: nil, confidenceSource: nil,
                startedAtUptimeNanos: 1, endedAtUptimeNanos: 2, inferenceDurationNanos: nil,
                warnings: [], fallbackReason: nil, termination: termination)
        }

        func testIncompleteMissingOrInconsistentFrameEvidenceCannotPromoteSuccess() {
            let valid = EngineFrameAccounting(
                capturedSourceSamples: 16_000, deliveredEngineSamples: 16_000,
                decodedEngineSamples: 16_000, droppedSourceSamples: 0)
            for completeness in EngineResultCompleteness.allCases {
                for termination in [EngineResultTermination.completed, .cancelled, .deadlineExceeded, .failed] {
                    let result = Self.result(completeness: completeness, accounting: valid, termination: termination)
                    let admitted = completeness == .complete && termination == .completed
                    XCTAssertEqual(result.isComplete, admitted)
                    let checked = result.requiringCompletionEvidence()
                    XCTAssertEqual(checked.isComplete, admitted)
                    XCTAssertEqual(checked.text, result.text)
                    XCTAssertEqual(checked.termination, termination)
                    XCTAssertEqual(checked.requiringCompletionEvidence(), checked)
                }
            }
            for accounting: EngineFrameAccounting? in [
                nil,
                .init(
                    capturedSourceSamples: 0, deliveredEngineSamples: 0, decodedEngineSamples: 0,
                    droppedSourceSamples: 0),
                .init(
                    capturedSourceSamples: 16_000, deliveredEngineSamples: 16_000, decodedEngineSamples: 15_999,
                    droppedSourceSamples: 0),
                .init(
                    capturedSourceSamples: 16_001, deliveredEngineSamples: 16_000, decodedEngineSamples: 16_000,
                    droppedSourceSamples: 1),
            ] {
                let result = Self.result(accounting: accounting).requiringCompletionEvidence()
                XCTAssertFalse(result.isComplete)
                XCTAssertEqual(result.completeness, .partial)
                XCTAssertTrue(result.warnings.contains(.captureDegraded))
                XCTAssertEqual(result.frameAccounting, accounting)
            }
            XCTAssertFalse(Self.result(text: " \n\t", accounting: valid).isComplete)
            XCTAssertTrue(Self.result(accounting: valid).isComplete)
        }

        func testMalformedRatiosAndOversizedCountsFailWithoutUnderflowOrConversionTraps() {
            let valid = EngineFrameAccounting(
                capturedSourceSamples: 16_000, deliveredEngineSamples: 16_000,
                decodedEngineSamples: 16_000, droppedSourceSamples: 0)
            for ratio in [Double.nan, .infinity, -.infinity, -1, 0, .greatestFiniteMagnitude] {
                XCTAssertFalse(valid.reconciled(converterRatio: ratio, roundingToleranceSamples: 64))
            }
            for (captured, delivered, dropped): (UInt64, UInt64, UInt64) in [(.max, .max, 0), (1, 1, 2), (0, 1, 0)] {
                let counts = EngineFrameAccounting(
                    capturedSourceSamples: captured, deliveredEngineSamples: delivered,
                    decodedEngineSamples: delivered, droppedSourceSamples: dropped)
                XCTAssertFalse(counts.reconciled(converterRatio: 1, roundingToleranceSamples: 64))
            }
            XCTAssertFalse(valid.reconciled(converterRatio: 1, roundingToleranceSamples: .max))
        }

        func testFractionalToleranceIsComparedWithoutRoundingDownDiscrepancy() {
            let counts = EngineFrameAccounting(
                capturedSourceSamples: 100, deliveredEngineSamples: 101,
                decodedEngineSamples: 101, droppedSourceSamples: 0)
            XCTAssertTrue(counts.reconciled(converterRatio: 1, roundingToleranceSamples: 1))
            XCTAssertFalse(counts.reconciled(converterRatio: 0.995, roundingToleranceSamples: 1))
            let resampled = EngineFrameAccounting(
                capturedSourceSamples: 48_000, deliveredEngineSamples: 16_000,
                decodedEngineSamples: 16_000, droppedSourceSamples: 0)
            XCTAssertTrue(resampled.reconciled(converterRatio: 1.0 / 3, roundingToleranceSamples: 0))
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
