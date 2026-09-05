#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private actor HeldDownload {
        private(set) var calls = 0
        private(set) var cancellations = 0
        private var closed = false
        private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        private var callbacks: [Int: @Sendable (ModelDownloadProgress) -> Void] = [:]

        func run(progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async {
            calls += 1
            let call = calls
            callbacks[call] = progress
            await withTaskCancellationHandler {
                if !closed { await withCheckedContinuation { waiters[call] = $0 } }
            } onCancel: {
                Task { await self.cancelObserved() }
            }
        }

        private func cancelObserved() { cancellations += 1 }
        func release(_ call: Int) { waiters.removeValue(forKey: call)?.resume() }
        func close() {
            closed = true
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func emit(_ call: Int, fraction: Double) {
            callbacks[call]?(.init(fraction: fraction, bytesDownloaded: 1, bytesExpected: 4))
        }
    }

    final class ProductionAcquisitionTests: XCTestCase {
        private enum FixtureError: Error { case timedOut }
        private func until(_ predicate: @Sendable () async -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !(await predicate()) {
                if clock.now >= deadline { throw FixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        private func fixture(_ gate: HeldDownload) throws -> ModelAcquisitionController {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("zf-acquisition-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Actual production filesystem, isolated root and synthetic
            // component bytes; no transport, model loader or personal cache.
            let fs = ProductionModelAcquisitionFileSystem(storageRoot: root) { _, staging, progress in
                await gate.run(progress: progress)
                // Deliberately ignores cancellation until the caller's
                // generation/cancellation checks reject its late completion.
                try Data("synthetic component".utf8).write(to: staging.appendingPathComponent("component.bin"))
            }
            let controller = ModelAcquisitionController(fs: fs) { model in
                ModelAcquisitionController.makeManifest(
                    for: model, createdAtUptimeNanos: 0, artifactNames: ["component.bin"],
                    optionalArtifactNames: [], minArtifactBytes: 1, minTotalBytes: 1, maxTotalBytes: 10_000)
            }
            addTeardownBlock {
                await controller.cancel(model: .whisperTiny)
                await gate.close()
                try FileManager.default.removeItem(at: root)
            }
            // Tests register task joins after this block; XCTest's LIFO teardown
            // joins them before removing this fixture's private root.
            return controller
        }

        func testOwnerCancellationReachesNativeTaskAndRetryWaitsForItsCompletion() async throws {
            let gate = HeldDownload()
            let controller = try fixture(gate)
            let owner = Task { await controller.acquire(model: .whisperTiny, consent: true) }
            addTeardownBlock {
                owner.cancel()
                await gate.close()
                _ = await owner.value
            }
            try await until { await gate.calls == 1 }
            owner.cancel()
            try await until { await gate.cancellations == 1 }
            let refused = await controller.acquire(model: .whisperTiny, consent: false)
            XCTAssertEqual(refused.error, .consentDenied, "a denied caller cannot join a consented flight")
            // A new request while native work is still held must join that
            // flight, not release its lock or start another native writer.
            let joining = Task { await controller.acquire(model: .whisperTiny, consent: true) }
            addTeardownBlock {
                joining.cancel()
                await gate.close()
                _ = await joining.value
            }
            try await until { await controller.coalescedRequests == 1 }
            await gate.release(1)
            let cancelled = await owner.value
            let joined = await joining.value
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(joined.state, .cancelled)
            let artifact = await controller.verifiedArtifact(for: .whisperTiny)
            XCTAssertNil(artifact)
            let calls = await gate.calls
            XCTAssertEqual(calls, 1)
            await gate.close()
            let retry = await controller.acquire(model: .whisperTiny, consent: true)
            XCTAssertEqual(retry.state, .ready)
            let verified = await controller.verifiedArtifact(for: .whisperTiny)
            XCTAssertNotNil(verified)
        }

        func testSupersededProgressCannotOverwriteNewAcquisition() async throws {
            let gate = HeldDownload()
            let controller = try fixture(gate)
            let first = Task { await controller.acquire(model: .whisperTiny, consent: true) }
            addTeardownBlock {
                first.cancel()
                await gate.close()
                _ = await first.value
            }
            try await until { await gate.calls == 1 }
            await controller.cancel(model: .whisperTiny)
            await gate.release(1)
            let cancelled = await first.value
            XCTAssertEqual(cancelled.state, .cancelled)

            let next = Task { await controller.acquire(model: .whisperTiny, consent: true) }
            addTeardownBlock {
                next.cancel()
                await gate.close()
                _ = await next.value
            }
            try await until { await gate.calls == 2 }
            await gate.emit(2, fraction: 0.25)
            try await until { await controller.progress[.whisperTiny]?.fraction == 0.25 }
            let ignored = await controller.ignoredProgressUpdates
            await gate.emit(1, fraction: 1)
            try await until { await controller.ignoredProgressUpdates > ignored }
            let currentProgress = await controller.progress[.whisperTiny]?.fraction
            XCTAssertEqual(currentProgress, 0.25)
            await gate.release(2)
            let result = await next.value
            XCTAssertEqual(result.state, .ready)
            let progress = await controller.progress[.whisperTiny]?.fraction
            XCTAssertNotEqual(progress, 1)
        }

        func testUnmeasuredOrInvalidFractionsStayIndeterminate() {
            let values: [Double?] = [nil, Double.nan, Double.infinity, -0.1, 1.1]
            for fraction in values {
                XCTAssertNil(ModelDownloadProgress(fraction: fraction, bytesDownloaded: 0, bytesExpected: nil).fraction)
            }
            XCTAssertEqual(ModelDownloadProgress(fraction: 0.25, bytesDownloaded: 1, bytesExpected: 4).fraction, 0.25)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
