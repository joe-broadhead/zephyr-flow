#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlowCore

    private final class AxWorkerFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: (@Sendable () -> Void)?
        private var clock: UInt64 = 100
        private var started = 0
        private var scheduled = 0
        let release = DispatchSemaphore(value: 0)
        var now: UInt64 { lock.withLock { clock } }
        var starts: Int { lock.withLock { started } }
        var submissions: Int { lock.withLock { scheduled } }
        func advance(to value: UInt64) { lock.withLock { clock = value } }
        func schedule(_ operation: @escaping @Sendable () -> Void) {
            lock.withLock {
                queued = operation
                scheduled += 1
            }
        }
        func dispatch() {
            let work = lock.withLock {
                let work = queued
                queued = nil
                return work
            }
            if let work { Thread.detachNewThread(work) }
        }
        func execute(held: Bool = false) -> Int {
            lock.withLock { started += 1 }
            if held { _ = release.wait(timeout: .now() + 10) }
            return 42
        }
    }

    private func awaitAxCondition(_ check: @Sendable () -> Bool) async throws {
        enum Failure: Error { case timedOut }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !check() {
            if clock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    final class AxBoundedRunnerTests: XCTestCase {
        func testCompletionReleasesLaneBeforeNextCall() async {
            let lane = AxOperationLane()
            for value in [1, 2, 3] {
                let result = await AxBoundedRunner.run(
                    deadlineNanosAhead: 5_000_000_000,
                    startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { value })
                XCTAssertEqual(result.value, value)
                XCTAssertFalse(lane.hasOutstandingWork)
            }
        }

        func testExpiredOrBackwardsClockNeverSchedulesNativeWork() async {
            let fixture = AxWorkerFixture()
            let lane = AxOperationLane(schedule: { fixture.schedule($0) })
            for (now, budget): (UInt64, UInt64) in [(100, 0), (200, 50), (99, 50)] {
                let result = await AxBoundedRunner.run(
                    deadlineNanosAhead: budget,
                    startedAtNanos: 100, nowNanos: { now }, lane: lane, operation: { fixture.execute() })
                guard case .deadlineExceeded = result else {
                    XCTFail("expired input must fail closed")
                    return
                }
            }
            XCTAssertEqual(fixture.submissions, 0)
            XCTAssertEqual(fixture.starts, 0)
            XCTAssertFalse(lane.hasOutstandingWork)
        }

        func testBudgetRecheckedWhenDelayedWorkerActuallyBegins() async throws {
            let fixture = AxWorkerFixture()
            let lane = AxOperationLane(schedule: { fixture.schedule($0) })
            let call = Task {
                await AxBoundedRunner.run(
                    deadlineNanosAhead: 5_000_000_000,
                    startedAtNanos: 100, nowNanos: { fixture.now }, lane: lane, operation: { fixture.execute() })
            }
            addTeardownBlock {
                call.cancel()
                fixture.dispatch()
                _ = await call.value
            }
            try await awaitAxCondition { fixture.submissions == 1 }
            fixture.advance(to: 5_000_000_100)
            fixture.dispatch()
            let result = await call.value
            guard case .deadlineExceeded = result else {
                XCTFail("late worker must not execute")
                return
            }
            XCTAssertEqual(fixture.starts, 0)
            XCTAssertFalse(lane.hasOutstandingWork)
        }

        func testCancellationBeforeWorkerAdmissionCannotExecuteOperation() async throws {
            let fixture = AxWorkerFixture()
            let lane = AxOperationLane(schedule: { fixture.schedule($0) })
            let call = Task {
                await AxBoundedRunner.run(
                    deadlineNanosAhead: 5_000_000_000,
                    startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { fixture.execute() })
            }
            addTeardownBlock {
                call.cancel()
                fixture.dispatch()
                _ = await call.value
            }
            try await awaitAxCondition { fixture.submissions == 1 }
            call.cancel()
            let result = await call.value
            guard case .cancelled(let mayHaveStarted) = result else {
                XCTFail("expected cancellation")
                return
            }
            XCTAssertFalse(mayHaveStarted)
            XCTAssertTrue(lane.hasOutstandingWork, "caller cancellation is not worker exit")
            fixture.dispatch()
            try await awaitAxCondition { !lane.hasOutstandingWork }
            XCTAssertEqual(fixture.starts, 0)
        }

        func testHeldNativeCancellationReturnsWithoutJoiningAndRejectsRetry() async throws {
            let fixture = AxWorkerFixture()
            let lane = AxOperationLane()
            let call = Task {
                await AxBoundedRunner.run(
                    deadlineNanosAhead: 5_000_000_000,
                    startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { fixture.execute(held: true) })
            }
            addTeardownBlock {
                call.cancel()
                fixture.release.signal()
                _ = await call.value
            }
            try await awaitAxCondition { fixture.starts == 1 }
            call.cancel()
            let result = await call.value
            guard case .cancelled(let mayHaveStarted) = result else {
                XCTFail("expected cancellation")
                return
            }
            XCTAssertTrue(mayHaveStarted)
            XCTAssertTrue(lane.hasOutstandingWork)
            let retry = await AxBoundedRunner.run(
                deadlineNanosAhead: 5_000_000_000,
                startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { fixture.execute() })
            guard case .busy = retry else {
                XCTFail("retry must not overlap cancelled native work")
                return
            }
            XCTAssertEqual(fixture.starts, 1)
            fixture.release.signal()
            try await awaitAxCondition { !lane.hasOutstandingWork }
            let next = await AxBoundedRunner.run(
                deadlineNanosAhead: 5_000_000_000,
                startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { 99 })
            XCTAssertEqual(next.value, 99, "late result cannot publish into next flight")
        }

        func testTimerReturnsWithoutJoiningHeldWorkerAndBoundsQueuedWork() async throws {
            let fixture = AxWorkerFixture()
            // Observe actual worker entry; a scheduled task alone is not proof
            // that native work started before the timer fired.
            let lane = AxOperationLane()
            let call = Task {
                await AxBoundedRunner.run(
                    deadlineNanosAhead: 500_000_000,
                    startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { fixture.execute(held: true) })
            }
            addTeardownBlock {
                call.cancel()
                fixture.release.signal()
                _ = await call.value
            }
            try await awaitAxCondition { fixture.starts == 1 }
            let result = await call.value
            guard case .deadlineExceeded = result else {
                XCTFail("expected timeout")
                return
            }
            XCTAssertTrue(lane.hasOutstandingWork)
            for _ in 0..<20 {
                let retry = await AxBoundedRunner.run(
                    deadlineNanosAhead: 5_000_000_000,
                    startedAtNanos: 100, nowNanos: { 100 }, lane: lane, operation: { fixture.execute() })
                guard case .busy = retry else {
                    XCTFail("timeout must not release native admission")
                    return
                }
            }
            XCTAssertEqual(fixture.starts, 1)
            fixture.release.signal()
            try await awaitAxCondition { !lane.hasOutstandingWork }
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
