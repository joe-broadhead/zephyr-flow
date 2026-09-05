#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    @MainActor
    private final class TargetReadApplication {
        var application: TargetApplicationMetadata? = .init(pid: 42, bundleID: "synthetic.target", version: "1")
        var trusted = true
        var heartbeat = 0
    }

    private final class TargetReadNativeFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let held: Bool
        let release = DispatchSemaphore(value: 0)
        var reads: Int { lock.withLock { calls } }
        init(held: Bool = false) { self.held = held }
        func read(app: TargetApplicationMetadata, now: UInt64) -> TargetValidationContext? {
            lock.withLock { calls += 1 }
            if held { _ = release.wait(timeout: .now() + 10) }
            return TargetValidationContext(
                pid: app.pid, bundleID: app.bundleID,
                processStartUptimeNanos: 123, windowID: 1,
                element: .init(role: "AXTextField", subrole: nil, resolutionToken: "synthetic-field"),
                settable: true, editable: true, enabled: true,
                sensitivity: .init(sensitivity: .normal, source: .accessibilityRole, capturedAtNanos: now),
                nowNanos: now)
        }
    }

    private func waitForTargetRead(_ condition: @Sendable () -> Bool) async throws {
        enum Failure: Error { case timedOut }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock().now < deadline else { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    final class ProductionTargetReadTests: XCTestCase {
        @MainActor
        private func service(
            app: TargetReadApplication, native: TargetReadNativeFixture,
            lane: AxOperationLane = AxOperationLane(), budget: UInt64 = 5_000_000_000
        ) -> TargetValidationService {
            TargetValidationService(
                application: { app.application }, trusted: { app.trusted },
                readMetadata: { native.read(app: $0, now: $1) }, readLane: lane, readBudgetNanos: budget)
        }

        func testMissingUntrustedIgnoredTargetsNeverInvokeNativeRead() async {
            let app = await TargetReadApplication()
            let native = TargetReadNativeFixture()
            let service = await service(app: app, native: native)
            for (bundle, trusted): (String?, Bool) in [
                (nil, true), ("synthetic.target", false), ("com.apple.SecurityAgent", true),
            ] {
                await MainActor.run {
                    app.application = bundle.map { TargetApplicationMetadata(pid: 42, bundleID: $0, version: "1") }
                    app.trusted = trusted
                }
                let result = await service.currentContext(nowNanos: 1)
                XCTAssertNil(result)
            }
            XCTAssertEqual(native.reads, 0)
        }

        func testSnapshotAndValidationUseSameBoundedMetadataPath() async {
            let app = await TargetReadApplication()
            let native = TargetReadNativeFixture()
            let service = await service(app: app, native: native)
            let sid = SessionID(token: "target-fixture", sequence: 1, createdAtUptimeNanos: 1)
            let snapshot = await service.captureSnapshot(sessionID: sid, nowNanos: 2)
            let context = await service.currentContext(nowNanos: 3)
            XCTAssertEqual(snapshot?.sessionID, sid)
            XCTAssertEqual(snapshot?.target.processStartUptimeNanos, 123)
            XCTAssertEqual(snapshot?.target.appVersion, "1")
            XCTAssertEqual(snapshot?.element, context?.element)
            XCTAssertEqual(snapshot?.sensitivity.sensitivity, .normal)
            XCTAssertEqual(context?.sensitivity.capturedAtNanos, 3)
            XCTAssertEqual(native.reads, 2)
        }

        func testHeldReadLeavesMainActorResponsiveAndTimeoutRetainsOneReader() async throws {
            let app = await TargetReadApplication()
            let native = TargetReadNativeFixture(held: true)
            let lane = AxOperationLane()
            let service = await service(app: app, native: native, lane: lane, budget: 500_000_000)
            let read = Task { await service.currentContext(nowNanos: 1) }
            addTeardownBlock {
                read.cancel()
                native.release.signal()
                _ = await read.value
            }
            try await waitForTargetRead { native.reads == 1 }
            await MainActor.run { app.heartbeat += 1 }
            let heartbeats = await app.heartbeat
            XCTAssertEqual(heartbeats, 1)
            let result = await read.value
            XCTAssertNil(result)
            XCTAssertTrue(lane.hasOutstandingWork)
            let retry = await service.currentContext(nowNanos: 2)
            XCTAssertNil(retry)
            XCTAssertEqual(native.reads, 1)
            native.release.signal()
            try await waitForTargetRead { !lane.hasOutstandingWork }
        }

        func testChangedApplicationOrRevokedTrustRejectsCompletedMetadata() async throws {
            for revoke in [false, true] {
                let app = await TargetReadApplication()
                let native = TargetReadNativeFixture(held: true)
                let service = await service(app: app, native: native)
                let read = Task { await service.currentContext(nowNanos: 1) }
                addTeardownBlock {
                    read.cancel()
                    native.release.signal()
                    _ = await read.value
                }
                try await waitForTargetRead { native.reads == 1 }
                await MainActor.run {
                    if revoke {
                        app.trusted = false
                    } else {
                        app.application = .init(pid: 43, bundleID: "synthetic.other", version: "1")
                    }
                }
                native.release.signal()
                let result = await read.value
                XCTAssertNil(result)
            }
        }

        func testCancellationRejectsLateSnapshotWithoutJoiningNativeRead() async throws {
            let app = await TargetReadApplication()
            let native = TargetReadNativeFixture(held: true)
            let lane = AxOperationLane()
            let service = await service(app: app, native: native, lane: lane)
            let sid = SessionID(token: "target-fixture", sequence: 1, createdAtUptimeNanos: 1)
            let read = Task { await service.captureSnapshot(sessionID: sid, nowNanos: 2) }
            addTeardownBlock {
                read.cancel()
                native.release.signal()
                _ = await read.value
            }
            try await waitForTargetRead { native.reads == 1 }
            read.cancel()
            let result = await read.value
            XCTAssertNil(result)
            XCTAssertTrue(lane.hasOutstandingWork)
            native.release.signal()
            try await waitForTargetRead { !lane.hasOutstandingWork }
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
