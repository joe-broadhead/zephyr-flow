#if canImport(XCTest)
    import WhisperKit
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private enum SyntheticEngineError: Error { case failed, timedOut, overlappingCall }

    private struct SyntheticRuntime: WhisperTranscriptionRuntime {
        func transcribe(samples: [Float], options: DecodingOptions) async throws -> String { "synthetic result" }
    }

    /// Deliberately ignores caller cancellation until explicitly completed.
    /// No models, microphone, permissions or network are involved.
    private actor ControlledRuntimeLoader {
        private var pending: [ModelIdentifier: CheckedContinuation<any WhisperTranscriptionRuntime, Error>] = [:]
        private var closed = false
        private(set) var configurations: [WhisperRuntimeConfiguration] = []

        func load(_ configuration: WhisperRuntimeConfiguration) async throws -> any WhisperTranscriptionRuntime {
            guard !closed else { throw CancellationError() }
            configurations.append(configuration)
            return try await withCheckedThrowingContinuation { pending[configuration.model] = $0 }
        }

        func finish(_ model: ModelIdentifier, fail: Bool = false) -> Bool {
            guard let continuation = pending.removeValue(forKey: model) else { return false }
            if fail {
                continuation.resume(throwing: SyntheticEngineError.failed)
            } else {
                continuation.resume(returning: SyntheticRuntime())
            }
            return true
        }

        func close() {
            closed = true
            let remaining = pending.values
            pending.removeAll()
            for continuation in remaining { continuation.resume(throwing: CancellationError()) }
        }

        func waitForCount(_ count: Int) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while configurations.count < count {
                guard clock.now < deadline else { throw SyntheticEngineError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    private actor ControlledNativeBackend: WhisperTranscriptionBackend {
        private var pending: CheckedContinuation<String, Error>?
        private var closed = false
        private(set) var calls = 0

        func transcribe(samples: [Float], options: DecodingOptions) async throws -> String {
            guard !closed else { throw CancellationError() }
            calls += 1
            // Fail rather than leak/overwrite a continuation if the production
            // guard regresses and admits an overlapping native call.
            guard pending == nil else { throw SyntheticEngineError.overlappingCall }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func finish(fail: Bool = false) {
            let continuation = pending
            pending = nil
            if fail {
                continuation?.resume(throwing: SyntheticEngineError.failed)
            } else {
                continuation?.resume(returning: "synthetic result")
            }
        }

        func close() {
            closed = true
            pending?.resume(throwing: CancellationError())
            pending = nil
        }

        func waitForCount(_ count: Int) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while calls < count {
                guard clock.now < deadline else { throw SyntheticEngineError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    final class ProductionEngineTests: XCTestCase {
        func testLateLoadCannotReplaceNewerRuntimeOrDigest() async throws {
            let loader = ControlledRuntimeLoader()
            addTeardownBlock { await loader.close() }
            let engine = WhisperKitEngine(runtimeFactory: { try await loader.load($0) })
            let older = Task { try await engine.load(model: .whisperTiny, verifiedFolder: "/synthetic/tiny") }
            try await loader.waitForCount(1)
            let newer = Task { try await engine.load(model: .whisperBase, verifiedFolder: "/synthetic/base") }
            try await loader.waitForCount(2)
            let pendingReady = await engine.isReady
            XCTAssertFalse(pendingReady)

            let finishedNew = await loader.finish(.whisperBase)
            XCTAssertTrue(finishedNew)
            try await newer.value
            await engine.recordVerifiedDigest("synthetic-new-digest")
            let name = await engine.modelName
            let finishedOld = await loader.finish(.whisperTiny)
            XCTAssertTrue(finishedOld)
            do {
                try await older.value
                XCTFail("stale initialization must not publish readiness")
            } catch is CancellationError {} catch { XCTFail("expected cancellation, got \(type(of: error))") }
            let ready = await engine.isReady
            let finalName = await engine.modelName
            let digest = await engine.verifiedDigest
            XCTAssertTrue(ready)
            XCTAssertEqual(finalName, name)
            XCTAssertEqual(digest, "synthetic-new-digest")
            let configurations = await loader.configurations
            XCTAssertEqual(configurations.map(\.allowDownload), [false, false])
            XCTAssertEqual(configurations.map(\.verifiedFolder), ["/synthetic/tiny", "/synthetic/base"])
        }

        func testStaleLoadFailureCannotClearNewReadiness() async throws {
            let loader = ControlledRuntimeLoader()
            addTeardownBlock { await loader.close() }
            let engine = WhisperKitEngine(runtimeFactory: { try await loader.load($0) })
            let older = Task { try await engine.load(model: .whisperTiny, allowDownload: false) }
            try await loader.waitForCount(1)
            let newer = Task { try await engine.load(model: .whisperBase, allowDownload: false) }
            try await loader.waitForCount(2)
            _ = await loader.finish(.whisperBase)
            try await newer.value
            _ = await loader.finish(.whisperTiny, fail: true)
            do {
                try await older.value
                XCTFail("expected synthetic load failure")
            } catch {}
            let ready = await engine.isReady
            XCTAssertTrue(ready)
        }

        func testCancelAndQuarantineInvalidateNoncooperativeLoadPublication() async throws {
            for quarantine in [false, true] {
                let loader = ControlledRuntimeLoader()
                addTeardownBlock { await loader.close() }
                let engine = WhisperKitEngine(runtimeFactory: { try await loader.load($0) })
                let load = Task { try await engine.load(model: .whisperTiny, allowDownload: false) }
                try await loader.waitForCount(1)
                if quarantine { await engine.quarantine() } else { await engine.cancel() }
                _ = await loader.finish(.whisperTiny)
                do {
                    try await load.value
                    XCTFail("invalidated load must not succeed")
                } catch is CancellationError {} catch { XCTFail("expected cancellation") }
                let ready = await engine.isReady
                XCTAssertFalse(ready)
            }
        }

        func testTaskCancellationAlsoPreventsReadyPublication() async throws {
            let loader = ControlledRuntimeLoader()
            addTeardownBlock { await loader.close() }
            let engine = WhisperKitEngine(runtimeFactory: { try await loader.load($0) })
            let load = Task { try await engine.load(model: .whisperTiny, allowDownload: false) }
            try await loader.waitForCount(1)
            load.cancel()
            _ = await loader.finish(.whisperTiny)
            do {
                try await load.value
                XCTFail("cancelled task must not publish")
            } catch is CancellationError {} catch { XCTFail("expected cancellation") }
            let ready = await engine.isReady
            XCTAssertFalse(ready)
        }

        func testReloadDuringStreamingIsRejectedWithoutChangingActiveModel() async throws {
            let engine = WhisperKitEngine(runtimeFactory: { _ in SyntheticRuntime() })
            try await engine.load(model: .whisperTiny, allowDownload: false)
            await engine.recordVerifiedDigest("synthetic-tiny")
            let name = await engine.modelName
            try await engine.startStreaming(
                sessionID: SessionID(token: "synthetic-session", sequence: 1, createdAtUptimeNanos: 0),
                localOnly: true, language: .auto, onPartial: { _ in })
            do {
                try await engine.load(model: .whisperBase, allowDownload: false)
                XCTFail("an active session owns its loaded model")
            } catch WhisperEngineError.decodeBusy {} catch { XCTFail("expected busy") }
            let activeName = await engine.modelName
            let digest = await engine.verifiedDigest
            let ready = await engine.isReady
            XCTAssertEqual(activeName, name)
            XCTAssertEqual(digest, "synthetic-tiny")
            XCTAssertTrue(ready)
            await engine.cancel()
        }

        func testVerifiedAdmissionNeverFallsBackWithoutArtifactFolder() async {
            let loader = ControlledRuntimeLoader()
            addTeardownBlock { await loader.close() }
            let engine = WhisperKitEngine(runtimeFactory: { try await loader.load($0) })
            do {
                try await engine.load(model: .whisperTiny, verifiedFolder: nil)
                XCTFail("missing artifact must fail before calling the factory")
            } catch {}
            let requests = await loader.configurations
            XCTAssertTrue(requests.isEmpty)
        }

        func testNativeOwnerRetainsAdmissionUntilCancelledCallActuallyReturns() async throws {
            let backend = ControlledNativeBackend()
            addTeardownBlock { await backend.close() }
            let runtime = WhisperKitRuntime(backend: backend)
            let first = Task { try await runtime.transcribe(samples: [0], options: DecodingOptions()) }
            try await backend.waitForCount(1)
            first.cancel()
            do {
                _ = try await runtime.transcribe(samples: [0], options: DecodingOptions())
                XCTFail("caller cancellation cannot clear native ownership")
            } catch WhisperEngineError.decodeBusy {} catch { XCTFail("expected busy") }
            let calls = await backend.calls
            XCTAssertEqual(calls, 1)
            await backend.finish()
            _ = try await first.value

            let second = Task { try await runtime.transcribe(samples: [0], options: DecodingOptions()) }
            try await backend.waitForCount(2)
            await backend.finish(fail: true)
            do {
                _ = try await second.value
                XCTFail("expected backend failure")
            } catch {}
            let third = Task { try await runtime.transcribe(samples: [0], options: DecodingOptions()) }
            try await backend.waitForCount(3)
            await backend.finish()
            let text = try await third.value
            XCTAssertEqual(text, "synthetic result", "both normal and throwing returns release admission")
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
