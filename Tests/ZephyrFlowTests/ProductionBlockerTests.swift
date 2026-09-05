#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    /// Round-5 REQ-2: the authoritative XCTest target must cover the blocker
    /// scenarios (not just the CLT executable). These are the pure Core
    /// contracts the production paths exercise — they run under
    /// `swift test --sanitize=address`.
    final class ProductionBlockerTests: XCTestCase {

        // Blocker 1 (round 5): incomplete consumer must degrade.
        func testIncompleteConsumerDegrades() {
            let degraded = AudioDrainAssessment.isDegraded(
                AudioDrainAssessment.Input(
                    seqDegraded: false, channelDegraded: false,
                    barrierTimedOut: false, barrierDrained: true,
                    consumerCompleted: false, lateAppends: 0, reconciled: true))
            XCTAssertTrue(degraded, "drained barrier + incomplete consumer must degrade")
            let ok = AudioDrainAssessment.isDegraded(
                AudioDrainAssessment.Input(
                    seqDegraded: false, channelDegraded: false,
                    barrierTimedOut: false, barrierDrained: true,
                    consumerCompleted: true, lateAppends: 0, reconciled: true))
            XCTAssertFalse(ok, "drained + complete consumer must not degrade")
            XCTAssertTrue(
                AudioDrainAssessment.shouldRetainOwnership(consumerCompleted: false),
                "ownership retained while consumer incomplete")
        }

        // Blocker 2 (round 5): press-edge intent invalidation.
        func testPressEdgeIntentInvalidation() async {
            let intent = PendingSessionIntent(
                generation: 1, pressTimestampNanos: 100, requestedMode: "hotkey")
            XCTAssertFalse(intent.isCancelled)
            intent.cancel()
            XCTAssertTrue(intent.isCancelled)
        }

        // Blocker 3 (round 5): stage-specific terminal vocabulary.
        func testStageSpecificTerminalVocabulary() {
            // Degraded is legal ONLY from .draining (drain-stage failure).
            var c = SessionControlModel()
            _ = c.begin()
            _ = c.stage(.readyToCapture)
            _ = c.stage(.stop)
            let reached = c.finish(category: .degraded)
            XCTAssertEqual(reached, .degraded)
            // Partial/truncated legal from .transforming.
            var c2 = SessionControlModel()
            _ = c2.begin()
            _ = c2.stage(.readyToCapture)
            _ = c2.stage(.stop)
            _ = c2.stage(.drainFinished)
            _ = c2.stage(.transcriptionFinished)
            let p = c2.finish(category: .partial)
            XCTAssertEqual(p, .partial)
            // Failed after Flow: resolvingTarget -> targetResolutionFailed.
            var c3 = SessionControlModel()
            _ = c3.begin()
            _ = c3.stage(.readyToCapture)
            _ = c3.stage(.stop)
            _ = c3.stage(.drainFinished)
            _ = c3.stage(.transcriptionFinished)
            _ = c3.stage(.transformationFinished)
            let f = c3.finish(category: .failed)
            XCTAssertEqual(f, .failed)
        }

        // Blocker 4 (round 5): exact TargetLease.
        func testTargetLeaseExactIdentity() {
            let sid = SessionID(token: "x", sequence: 1, createdAtUptimeNanos: 0)
            func snap(pid: Int32 = 42, start: UInt64 = 900, win: UInt32? = 7, tok: String? = "t") -> TargetSnapshot {
                TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 0,
                    target: .init(
                        pid: pid, bundleID: "com.e", processStartUptimeNanos: start, windowID: win, appVersion: "1"),
                    element: .init(role: "AXTextField", subrole: nil, resolutionToken: tok),
                    settable: true, editable: true, enabled: true,
                    selectionRange: 0..<0,
                    sensitivity: .init(sensitivity: .normal, source: .accessibilityRole, capturedAtNanos: 0))
            }
            let s = snap()
            let lease = TargetLease.make(
                snapshot: s, sessionID: sid, validationDeadlineNanosAhead: 1_000_000_000, nowNanos: 0)
            XCTAssertTrue(lease.matches(reResolved: s, requireWindow: true, requireElementToken: true, nowNanos: 100))
            XCTAssertFalse(
                lease.matches(reResolved: snap(win: 8), requireWindow: true, requireElementToken: true, nowNanos: 100))
            XCTAssertFalse(
                lease.matches(
                    reResolved: snap(start: 901), requireWindow: true, requireElementToken: true, nowNanos: 100))
            XCTAssertFalse(
                lease.matches(reResolved: s, requireWindow: true, requireElementToken: true, nowNanos: 2_000_000_000))
        }

        // Blocker 5 (round 5): verified manifest enumerates all components.
        func testVerifiedManifestEnumeratesWhisperKitComponents() throws {
            let m = ModelAcquisitionController.makeManifest(for: .whisperTiny, createdAtUptimeNanos: 0)
            let names = Set(m.artifacts.map { $0.name })
            XCTAssertEqual(
                names,
                Set([
                    "config.json", "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc",
                    "TextDecoder.mlmodelc", "TextDecoderContextPrefill.mlmodelc", "tokenizer",
                ]))
            XCTAssertEqual(names.count, m.artifacts.count, "manifest must not contain duplicate assets")
            XCTAssertEqual(
                Set(m.artifacts.filter { $0.isOptional }.map { $0.name }),
                Set(["TextDecoderContextPrefill.mlmodelc"]))
            let tokenizer = try XCTUnwrap(m.artifacts.first { $0.name == "tokenizer" })
            XCTAssertFalse(tokenizer.isOptional, "the staged tokenizer directory is required")
        }

        // REQ-5: explicit history states.
        func testHistoryStorageStates() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zf-xctest-req5-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer {
                do {
                    try FileManager.default.removeItem(at: dir)
                } catch {
                    XCTFail("temporary history cleanup failed")
                }
            }
            let key = HistoryCryptoKey(keyID: "k", material: Data(repeating: 0x11, count: 32))
            let repo = ActorHistoryRepository(fileURL: file, keyProvider: { key })
            await repo.configureEncryption(keyProvider: { key })
            try await repo.load()
            let state = await repo.storageState
            XCTAssertEqual(state, .readyEncrypted)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
