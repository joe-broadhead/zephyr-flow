#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private actor AdmissionTrace {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private actor AdmissionHistory: HistoryRepository {
        let trace: AdmissionTrace
        let ready: Bool
        let held: Bool
        private(set) var attempts = 0
        private var continuation: AsyncStream<Void>.Continuation?
        init(trace: AdmissionTrace, ready: Bool = true, held: Bool = false) {
            self.trace = trace
            self.ready = ready
            self.held = held
        }
        func prepareForSession(saveHistory: Bool) async -> Bool {
            attempts += 1
            await trace.record("history")
            if held {
                let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
                self.continuation = continuation
                for await _ in stream { break }
            }
            return !Task.isCancelled && ready
        }
        func release() {
            continuation?.finish()
            continuation = nil
        }
        func add(_ entry: HistoryEntry) async { await trace.record("writeHistory") }
    }

    private struct AdmissionTarget: TargetValidationProviding {
        let sensitivity: SessionSensitivity?
        let trace: AdmissionTrace
        func captureSnapshot(sessionID: SessionID, nowNanos: UInt64) async -> TargetSnapshot? {
            await trace.record("target")
            guard let sensitivity else { return nil }
            return TargetSnapshot(
                sessionID: sessionID, capturedAtUptimeNanos: nowNanos,
                target: .init(
                    pid: 42, bundleID: "synthetic.target", processStartUptimeNanos: 1, windowID: 1, appVersion: nil),
                element: .init(role: "AXTextField", subrole: nil, resolutionToken: "synthetic-field"),
                settable: true, editable: true, enabled: true, selectionRange: nil,
                sensitivity: .init(sensitivity: sensitivity, source: .accessibilityRole, capturedAtNanos: nowNanos))
        }
        func currentContext(nowNanos: UInt64) async -> TargetValidationContext? { nil }
        func restoreToCapturedTarget(snapshot: TargetSnapshot, deadlineNanosAhead: UInt64) async -> TargetRestoreMonitor
        {
            TargetRestoreMonitor(deadlineNanosAhead: deadlineNanosAhead)
        }
    }

    final class ProductionAdmissionTests: XCTestCase {
        private enum FixtureError: Error { case timedOut }
        private func fixture(
            sensitivity: SessionSensitivity?, saveHistory: Bool, ready: Bool = true, held: Bool = false
        )
            -> (DictationSession, FakeWhisperEngine, AdmissionHistory, AdmissionTrace)
        {
            let trace = AdmissionTrace()
            let history = AdmissionHistory(trace: trace, ready: ready, held: held)
            let engine = FakeWhisperEngine()
            let target = AdmissionTarget(sensitivity: sensitivity, trace: trace)
            let environment = AppEnvironment.test(engine: engine, history: history, target: target)
            // Actual production stages, but fake engine/AX/history. Apple kind
            // avoids the Whisper audio route; no capture is invoked by admission.
            let provider = ProductionSessionStages(environment: environment, engine: engine, engineKind: .appleSpeech)
            let session = DictationSession(
                provider: provider, engineChoice: .appleSpeech,
                settings: .init(
                    localOnly: true, language: .enUS, defaultFlowStyle: .raw,
                    insertionMode: "automatic", saveHistory: saveHistory, copyOnlyOverrideBundleIDs: []))
            return (session, engine, history, trace)
        }

        func testOnlyNormalOptedInAdmissionTouchesHistoryAndNeverStartsRecording() async {
            let sensitivities: [SessionSensitivity?] = [nil, .unknown, .secure, .normal]
            for sensitivity in sensitivities {
                for save in [false, true] {
                    let (session, engine, history, trace) = fixture(sensitivity: sensitivity, saveHistory: save)
                    let result = await session.prepareAdmission()
                    let repeated = await session.prepareAdmission()
                    XCTAssertEqual(result, .ready)
                    XCTAssertEqual(repeated, .ready)
                    let events = await trace.events
                    let attempts = await history.attempts
                    let starts = await engine.streamStarts
                    let expectedHistory = save && sensitivity == .normal
                    XCTAssertEqual(events, expectedHistory ? ["target", "history"] : ["target"])
                    XCTAssertEqual(attempts, expectedHistory ? 1 : 0)
                    XCTAssertEqual(starts, 0)
                    let snapshot = await session.targetSnapshot
                    XCTAssertEqual(snapshot?.sensitivity.sensitivity, sensitivity)
                }
            }
        }

        func testHistoryFailurePreventsCaptureAndDirectRunEmitsOneFailureTerminal() async {
            let (session, engine, _, trace) = fixture(sensitivity: .normal, saveHistory: true, ready: false)
            await session.run()
            await session.run()
            let starts = await engine.streamStarts
            let events = await trace.events
            let telemetry = await session.drainTelemetry()
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(events, ["target", "history"])
            XCTAssertEqual(telemetry.filter { $0.kind == .terminal }.map(\.terminal), [.failed])
        }

        func testCancellationDuringHistoryWaitRejectsLateAdmissionWithoutCapture() async throws {
            let (session, engine, history, _) = fixture(sensitivity: .normal, saveHistory: true, held: true)
            let preparation = Task { await session.prepareAdmission() }
            addTeardownBlock {
                preparation.cancel()
                await history.release()
                _ = await preparation.value
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while await history.attempts == 0 {
                if clock.now >= deadline { throw FixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            preparation.cancel()
            let result = await preparation.value
            XCTAssertEqual(result, .cancelled)
            await history.release()
            let starts = await engine.streamStarts
            XCTAssertEqual(starts, 0)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
