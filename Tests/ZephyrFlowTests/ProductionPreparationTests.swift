#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private enum PreparationTestError: Error { case timedOut, failed }

    private func awaitPreparationCondition(_ condition: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw PreparationTestError.timedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private actor PreparationCompletion {
        private(set) var finished = false
        func finish() { finished = true }
    }

    private actor PreparationTestEngine: WhisperEngineProtocol {
        private(set) var isReady = false
        private(set) var isQuarantined = false
        private(set) var verifiedDigest: String?
        var modelName: String { "Synthetic preparation engine" }
        private(set) var loads: [(model: ModelIdentifier, folder: String?)] = []
        private(set) var captures = 0
        private let held: Bool
        private let fails: Bool
        private var closed = false
        private var continuation: CheckedContinuation<Void, Error>?

        init(held: Bool = false, fails: Bool = false) {
            self.held = held
            self.fails = fails
        }

        func load(model: ModelIdentifier, verifiedFolder: String?) async throws {
            guard !closed else { throw CancellationError() }
            loads.append((model, verifiedFolder))
            if held { try await withCheckedThrowingContinuation { continuation = $0 } }
            if fails { throw PreparationTestError.failed }
            isReady = true
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
        func close() {
            closed = true
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
        func recordVerifiedDigest(_ digest: String?) { verifiedDigest = digest }
        func startStreaming(
            sessionID: SessionID, localOnly: Bool, language: SupportedLanguage,
            onPartial: @escaping @Sendable (PartialTranscription) -> Void
        ) async throws { captures += 1 }
        func appendAudio(_ samples: [Float]) async {}
        func stopAndFinalize() async throws -> FinalTranscription { throw PreparationTestError.failed }
        func cancel() async {}  // Deliberately noncooperative native-load simulation.
        func quarantine() async { isQuarantined = true }
    }

    private actor PreparationArtifacts {
        private var models: Set<ModelIdentifier>
        private(set) var lookups: [ModelIdentifier] = []
        private(set) var acquisitions: [(ModelIdentifier, Bool)] = []
        init(_ models: Set<ModelIdentifier>) { self.models = models }

        func lookup(_ model: ModelIdentifier) -> EnginePreparationCoordinator.Artifact? {
            lookups.append(model)
            guard models.contains(model) else { return nil }
            return .init(
                folder: URL(fileURLWithPath: "/synthetic/\(model.rawValue)"), manifestVersion: 1,
                aggregateDigest: "synthetic-digest-\(model.rawValue)")
        }

        func acquire(_ model: ModelIdentifier, consent: Bool) throws {
            acquisitions.append((model, consent))
            guard consent else { throw PreparationTestError.failed }
            models.insert(model)
        }
    }

    private final class PreparationFactory: @unchecked Sendable {
        // Only mutable state is the queue of Sendable actors; every access is
        // within withLock and no lock spans an await.
        private let lock = NSLock()
        private var engines: [ModelIdentifier: [PreparationTestEngine]]
        init(_ engines: [ModelIdentifier: [PreparationTestEngine]]) { self.engines = engines }
        func make(_ model: ModelIdentifier) throws -> any WhisperEngineProtocol {
            try lock.withLock {
                guard var queue = engines[model], !queue.isEmpty else { throw PreparationTestError.failed }
                let first = queue.removeFirst()
                engines[model] = queue
                return first
            }
        }
    }

    final class ProductionPreparationTests: XCTestCase {
        private func request(_ model: ModelIdentifier, downloads: Bool = false) -> EnginePreparationRequest {
            var settings = AppSettings.default
            settings.preferredModel = model
            settings.allowModelDownloads = downloads
            return EnginePreparationRequest(settings: settings)
        }

        private func coordinator(
            artifacts: PreparationArtifacts, engines: [ModelIdentifier: [PreparationTestEngine]]
        ) async -> EnginePreparationCoordinator {
            let factory = PreparationFactory(engines)
            let coordinator = await MainActor.run {
                EnginePreparationCoordinator(
                    makeEngine: { try factory.make($0) },
                    lookup: { await artifacts.lookup($0) },
                    acquire: { try await artifacts.acquire($0, consent: $1) })
            }
            addTeardownBlock {
                await coordinator.cancel()
                for list in engines.values { for engine in list { await engine.close() } }
            }
            return coordinator
        }

        func testMissingArtifactRequiresConsentWithoutLoadingOrCapturing() async {
            let artifacts = PreparationArtifacts([])
            let engine = PreparationTestEngine()
            let coordinator = await coordinator(artifacts: artifacts, engines: [.whisperTiny: [engine]])
            let value = await coordinator.prepare(request(.whisperTiny))
            let phase = await coordinator.phase
            let acquisitions = await artifacts.acquisitions
            let loads = await engine.loads
            let captures = await engine.captures
            XCTAssertNil(value)
            XCTAssertEqual(phase, .consentRequired)
            XCTAssertTrue(acquisitions.isEmpty)
            XCTAssertTrue(loads.isEmpty)
            XCTAssertEqual(captures, 0)
        }

        func testAcquiredFilesDoNotPublishReadyBeforeEngineLoad() async throws {
            let artifacts = PreparationArtifacts([])
            let engine = PreparationTestEngine(held: true)
            let coordinator = await coordinator(artifacts: artifacts, engines: [.whisperTiny: [engine]])
            let request = request(.whisperTiny, downloads: true)
            let task = Task { await coordinator.prepare(request) }
            try await awaitPreparationCondition { await engine.loads.count == 1 }
            let phase = await coordinator.phase
            let acquisitions = await artifacts.acquisitions
            let captures = await engine.captures
            XCTAssertEqual(phase, .loading)
            XCTAssertEqual(acquisitions.count, 1)
            XCTAssertTrue(acquisitions[0].1)
            XCTAssertEqual(captures, 0)
            await engine.release()
            let result = await task.value
            let digest = await result?.engine.verifiedDigest
            XCTAssertNotNil(result)
            XCTAssertEqual(digest, "synthetic-digest-\(ModelIdentifier.whisperTiny.rawValue)")
        }

        func testAppleSelectionLoadsAppleWithoutModelAcquisition() async throws {
            let artifacts = PreparationArtifacts([])
            let apple = PreparationTestEngine()
            let coordinator = await coordinator(artifacts: artifacts, engines: [.appleSpeech: [apple]])
            let result = await coordinator.prepare(request(.appleSpeech))
            let loads = await apple.loads
            let lookups = await artifacts.lookups
            let acquisitions = await artifacts.acquisitions
            XCTAssertEqual(result?.request.model, .appleSpeech)
            XCTAssertEqual(loads.count, 1)
            XCTAssertEqual(loads.first?.model, .appleSpeech)
            XCTAssertNil(loads.first?.folder)
            XCTAssertTrue(lookups.isEmpty)
            XCTAssertTrue(acquisitions.isEmpty)
        }

        func testCancelledWaiterReturnsBeforeNoncooperativeNativeWorkEnds() async throws {
            let engine = PreparationTestEngine(held: true)
            let artifacts = PreparationArtifacts([.whisperTiny])
            let coordinator = await coordinator(artifacts: artifacts, engines: [.whisperTiny: [engine]])
            let completion = PreparationCompletion()
            let request = request(.whisperTiny)
            let task = Task {
                let result = await coordinator.prepare(request)
                await completion.finish()
                return result
            }
            try await awaitPreparationCondition { await engine.loads.count == 1 }
            task.cancel()
            try await awaitPreparationCondition { await completion.finished }
            let result = await task.value
            let phase = await coordinator.phase
            let workers = await coordinator.outstandingWorkers
            XCTAssertNil(result)
            XCTAssertEqual(phase, .cancelled)
            XCTAssertEqual(workers, 1, "cancellation is not native completion")
            await engine.release()
            try await awaitPreparationCondition { await coordinator.outstandingWorkers == 0 }
            let digest = await engine.verifiedDigest
            XCTAssertNil(digest, "late completion cannot publish the cancelled candidate")
        }

        func testNewWhisperSelectionCoalescesBehindOldLoadAndDiscardsIntermediateChoice() async throws {
            let tiny = PreparationTestEngine(held: true)
            let base = PreparationTestEngine()
            let small = PreparationTestEngine()
            let artifacts = PreparationArtifacts([.whisperTiny, .whisperBase, .whisperSmall])
            let coordinator = await coordinator(
                artifacts: artifacts, engines: [.whisperTiny: [tiny], .whisperBase: [base], .whisperSmall: [small]])
            let tinyRequest = request(.whisperTiny)
            let baseRequest = request(.whisperBase)
            let smallRequest = request(.whisperSmall)
            let first = Task { await coordinator.prepare(tinyRequest) }
            try await awaitPreparationCondition { await tiny.loads.count == 1 }
            let middle = Task { await coordinator.prepare(baseRequest) }
            try await awaitPreparationCondition { await coordinator.request == baseRequest }
            let last = Task { await coordinator.prepare(smallRequest) }
            try await awaitPreparationCondition { await coordinator.request == smallRequest }
            let workers = await coordinator.outstandingWorkers
            let baseLoads = await base.loads
            XCTAssertEqual(workers, 1)
            XCTAssertTrue(baseLoads.isEmpty)
            await tiny.release()
            let newest = await last.value
            let stale = await first.value
            let discarded = await middle.value
            let staleDigest = await tiny.verifiedDigest
            XCTAssertEqual(newest?.request.model, .whisperSmall)
            XCTAssertNil(stale)
            XCTAssertNil(discarded)
            XCTAssertNil(staleDigest)
        }

        func testAppleFallbackCanPrepareWhileSupersededWhisperIsStillFinishing() async throws {
            let tiny = PreparationTestEngine(held: true)
            let apple = PreparationTestEngine()
            let artifacts = PreparationArtifacts([.whisperTiny])
            let coordinator = await coordinator(
                artifacts: artifacts, engines: [.whisperTiny: [tiny], .appleSpeech: [apple]])
            let whisperRequest = request(.whisperTiny)
            let appleRequest = request(.appleSpeech)
            let old = Task { await coordinator.prepare(whisperRequest) }
            try await awaitPreparationCondition { await tiny.loads.count == 1 }
            let next = Task { await coordinator.prepare(appleRequest) }
            try await awaitPreparationCondition { await coordinator.phase == .ready }
            let result = await next.value
            XCTAssertEqual(result?.request.model, .appleSpeech)
            await tiny.release()
            _ = await old.value
            try await awaitPreparationCondition { await coordinator.outstandingWorkers == 0 }
            let current = await coordinator.request
            XCTAssertEqual(current, appleRequest)
        }

        func testRetryAndQuarantineUseFreshCandidatesWithoutMutatingPriorSessionEngine() async throws {
            let failed = PreparationTestEngine(fails: true)
            let first = PreparationTestEngine()
            let replacement = PreparationTestEngine()
            let artifacts = PreparationArtifacts([.whisperTiny])
            let coordinator = await coordinator(
                artifacts: artifacts, engines: [.whisperTiny: [failed, first, replacement]])
            let request = request(.whisperTiny)
            let failure = await coordinator.prepare(request)
            let noImplicitRetry = await coordinator.prepare(request)
            XCTAssertNil(failure)
            XCTAssertNil(noImplicitRetry)
            let prepared = await coordinator.prepare(request, retry: true)
            let cached = await coordinator.prepare(request)
            XCTAssertEqual(prepared?.token, cached?.token)
            let sessionEngine = try XCTUnwrap(prepared?.engine)
            try await sessionEngine.startStreaming(
                sessionID: SessionID(token: "synthetic", sequence: 1, createdAtUptimeNanos: 0),
                localOnly: true, language: .auto, onPartial: { _ in })
            await first.quarantine()
            let newer = await coordinator.prepare(request)
            let newEngine = try XCTUnwrap(newer?.engine)
            XCTAssertFalse(sessionEngine === newEngine)
            let oldLoads = await first.loads
            let oldCaptures = await first.captures
            XCTAssertEqual(oldLoads.count, 1)
            XCTAssertEqual(oldCaptures, 1)
            XCTAssertNotEqual(prepared?.token, newer?.token)
            if let prepared {
                let obsolete = await coordinator.isCurrent(prepared)
                XCTAssertFalse(obsolete)
            }
        }

        func testLateFailedWhisperCannotReplaceReadyAppleState() async throws {
            let tiny = PreparationTestEngine(held: true, fails: true)
            let apple = PreparationTestEngine()
            let artifacts = PreparationArtifacts([.whisperTiny])
            let coordinator = await coordinator(
                artifacts: artifacts, engines: [.whisperTiny: [tiny], .appleSpeech: [apple]])
            let whisperRequest = request(.whisperTiny)
            let old = Task { await coordinator.prepare(whisperRequest) }
            try await awaitPreparationCondition { await tiny.loads.count == 1 }
            let ready = await coordinator.prepare(request(.appleSpeech))
            XCTAssertNotNil(ready)
            await tiny.release()
            _ = await old.value
            try await awaitPreparationCondition { await coordinator.outstandingWorkers == 0 }
            let phase = await coordinator.phase
            XCTAssertEqual(phase, .ready)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
