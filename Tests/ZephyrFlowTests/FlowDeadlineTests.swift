#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    private actor HeldFlowBackend: FlowProcessorProtocol {
        private(set) var requests: [FlowRequest] = []
        private var held: Bool
        private var continuations: [CheckedContinuation<Void, Never>] = []
        init(held: Bool = true) { self.held = held }
        func process(_ text: String, style: FlowStyle) async -> String { text }
        func process(_ request: FlowRequest) async -> FlowOutcome {
            requests.append(request)
            // Deliberately ignores task cancellation until the test releases
            // it; the production router must not mistake cancel for completion.
            if held { await withCheckedContinuation { continuations.append($0) } }
            return await FlowProcessor().process(request)
        }
        func release() {
            held = false
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    private actor HeldFlowConfiguration {
        private(set) var calls = 0
        private var held = true
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func backend() async -> FlowBackend {
            calls += 1
            if held { await withCheckedContinuation { continuations.append($0) } }
            return .regex
        }
        func release() {
            held = false
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    final class FlowDeadlineTests: XCTestCase {
        private enum FixtureError: Error { case timedOut }
        private func until(_ predicate: @Sendable () async -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !(await predicate()) {
                if clock.now >= deadline { throw FixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        private func request(
            _ sequence: UInt64 = 1, style: FlowStyle = .professional, sensitivity: SessionSensitivity = .normal,
            deadline: UInt64 = 100_000_000
        ) -> FlowRequest {
            .init(
                sessionID: SessionID(token: "flow-deadline", sequence: sequence, createdAtUptimeNanos: 0),
                text: "  synthetic input with -12 kg and café 👩🏽‍💻  ", style: style, language: .enUS,
                sensitivity: sensitivity, deadlineNanosAhead: deadline)
        }

        func testRequestDeadlineReturnsVerbatimWithoutJoiningUncooperativeEnhanced() async throws {
            let backend = HeldFlowBackend()
            addTeardownBlock { await backend.release() }
            let router = FlowRouter()
            await router.configure(backend: { .enhanced }, enhancedReady: { true }, enhanced: backend)
            let req = request()
            let output = await router.process(req)
            XCTAssertEqual(output.status, .deadlineExceeded)
            XCTAssertEqual(output.text, req.text)
            XCTAssertEqual(output.resolvedLossClass, .verbatim)
            XCTAssertEqual(output.changedRangeCount, 0)
            XCTAssertTrue(output.protectedSpansPreserved)
            let held = await router.hasOutstandingWork
            XCTAssertTrue(held)
            await backend.release()
            try await until { !(await router.hasOutstandingWork) }
        }

        func testDeadlineIncludesRegexAndConfigurationWaits() async throws {
            let backend = HeldFlowBackend()
            addTeardownBlock { await backend.release() }
            let router = FlowRouter(regex: backend)
            let out = await router.process(request(style: .clean))
            XCTAssertEqual(out.status, .deadlineExceeded)
            let held = await router.hasOutstandingWork
            XCTAssertTrue(held)
            await backend.release()
            try await until { !(await router.hasOutstandingWork) }

            let configuration = HeldFlowConfiguration()
            addTeardownBlock { await configuration.release() }
            await router.configure(backend: { await configuration.backend() }, enhancedReady: { false }, enhanced: nil)
            let waiting = await router.process(request())
            XCTAssertEqual(waiting.status, .deadlineExceeded)
            let calls = await configuration.calls
            XCTAssertEqual(calls, 1)
            await configuration.release()
            try await until { !(await router.hasOutstandingWork) }
        }

        func testEnhancedSoftDeadlineAlsoReturnsWithoutJoiningNativeWork() async throws {
            let backend = HeldFlowBackend()
            addTeardownBlock { await backend.release() }
            let router = FlowRouter(enhancedTimeoutNanoseconds: 100_000_000)
            await router.configure(backend: { .enhanced }, enhancedReady: { true }, enhanced: backend)
            let output = await router.process(request(deadline: 5_000_000_000))
            XCTAssertEqual(output.status, .deadlineExceeded)
            XCTAssertTrue(output.warnings.contains(.enhancedTimeout))
            let held = await router.hasOutstandingWork
            XCTAssertTrue(held)
            await backend.release()
            try await until { !(await router.hasOutstandingWork) }
        }

        func testCancelReturnsAndNewRequestCannotQueueMoreNativeWorkOrReceiveOldText() async throws {
            let backend = HeldFlowBackend()
            let router = FlowRouter(regex: backend)
            let req = request(deadline: 5_000_000_000)
            let task = Task { await router.process(req) }
            addTeardownBlock {
                task.cancel()
                await backend.release()
                _ = await task.value
            }
            try await until { await backend.requests.count == 1 }
            task.cancel()
            let cancelled = await task.value
            XCTAssertEqual(cancelled.termination, .cancelled)
            let busy = await router.process(request(2))
            XCTAssertEqual(busy.status, .rejected)
            XCTAssertTrue(busy.warnings.contains(.verbatimFallback))
            let requests = await backend.requests
            XCTAssertEqual(requests.map(\.sessionID), [req.sessionID])
            await backend.release()
            try await until { !(await router.hasOutstandingWork) }
            let next = await router.process(request(3, style: .clean, deadline: 1_000_000_000))
            XCTAssertEqual(next.status, .accepted)
            let finalRequests = await backend.requests
            XCTAssertEqual(finalRequests.map(\.sessionID), [req.sessionID, request(3).sessionID])
        }

        func testZeroDeadlineNeverCallsBackendAndSecurePolicySkipsEnhancedConfiguration() async {
            let backend = HeldFlowBackend(held: false)
            let configuration = HeldFlowConfiguration()
            addTeardownBlock { await configuration.release() }
            let router = FlowRouter(regex: backend)
            await router.configure(
                backend: { await configuration.backend() }, enhancedReady: { true }, enhanced: backend)
            let expired = await router.process(request(deadline: 0))
            XCTAssertEqual(expired.status, .deadlineExceeded)
            let callsBefore = await backend.requests.count
            XCTAssertEqual(callsBefore, 0)
            let secure = await router.process(request(sensitivity: .secure, deadline: 1_000_000_000))
            XCTAssertTrue(secure.warnings.contains(.secureSensitivityConservative))
            let configurationCalls = await configuration.calls
            let requests = await backend.requests
            XCTAssertEqual(configurationCalls, 0)
            XCTAssertEqual(requests.first?.style, .clean)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
