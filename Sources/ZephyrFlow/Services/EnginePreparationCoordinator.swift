import Combine
import Foundation
import ZephyrFlowCore

struct EnginePreparationRequest: Sendable, Equatable {
    let model: ModelIdentifier
    let allowDownloads: Bool
    let localOnly: Bool
    let language: SupportedLanguage

    init(settings: AppSettings) {
        model = settings.preferredModel
        allowDownloads = settings.mayDownloadModels
        localOnly = settings.localOnlyMode
        language = settings.language
    }
}

enum EnginePreparationPhase: Equatable {
    case idle, queued, verifying, acquiring, loading, ready, consentRequired, cancelled, failed
    case unavailable(SpeechCapabilityFailure)
    case insufficientSpace

    var isBusy: Bool { [.queued, .verifying, .acquiring, .loading].contains(self) }

    var message: String? {
        switch self {
        case .idle: return nil
        case .queued: return AppStrings.key("engine.preparation.waiting")
        case .verifying: return AppStrings.key("engine.preparation.verifying")
        case .acquiring: return AppStrings.key("engine.preparation.acquiring")
        case .loading: return AppStrings.key("engine.preparation.loading")
        case .ready: return AppStrings.key("engine.preparation.ready")
        case .consentRequired: return AppStrings.key("engine.preparation.consent")
        case .cancelled: return AppStrings.key("engine.preparation.cancelled")
        case .failed: return AppStrings.key("engine.preparation.failed")
        case .unavailable(let failure): return failure.message
        case .insufficientSpace: return AppStrings.key("engine.preparation.diskspace")
        }
    }
}

struct PreparedEngine: Sendable {
    let generation: UUID
    let request: EnginePreparationRequest
    let engine: any WhisperEngineProtocol
    let token: EngineToken
}

/// Application preparation boundary: artifact acquisition is not readiness.
/// Only a loaded, current candidate can be handed to session admission.
/// Candidates are fresh instances; never reload an engine owned by a session.
@MainActor
final class EnginePreparationCoordinator: ObservableObject {
    typealias Artifact = ModelAcquisitionController.VerifiedModelArtifact
    typealias EngineFactory = @Sendable (ModelIdentifier) throws -> any WhisperEngineProtocol
    typealias ArtifactLookup = @Sendable (ModelIdentifier) async -> Artifact?
    typealias Acquisition = @Sendable (ModelIdentifier, Bool) async throws -> Void

    @Published private(set) var phase: EnginePreparationPhase = .idle
    private(set) var request: EnginePreparationRequest?
    private var generation: UUID?
    private var prepared: PreparedEngine?
    private let makeEngine: EngineFactory
    private let lookup: ArtifactLookup
    private let acquire: Acquisition
    private let freeBytes: @Sendable () async -> UInt64
    // At most one native preparation per backend kind. Superseding Whisper
    // requests coalesce while an old initializer finishes; Apple can proceed
    // independently. A cancellation flag is never treated as native completion.
    private var workers: [Bool: (id: UUID, task: Task<Void, Never>)] = [:]
    private var waiters: [UUID: AsyncStream<PreparedEngine>.Continuation] = [:]

    var outstandingWorkers: Int { workers.count }

    init(
        makeEngine: @escaping EngineFactory, lookup: @escaping ArtifactLookup, acquire: @escaping Acquisition,
        freeBytes: @escaping @Sendable () async -> UInt64 = { UInt64.max }
    ) {
        self.makeEngine = makeEngine
        self.lookup = lookup
        self.acquire = acquire
        self.freeBytes = freeBytes
    }

    static func production(engines: EngineRegistry) -> EnginePreparationCoordinator {
        let store = ModelReadinessStore.shared
        return EnginePreparationCoordinator(
            makeEngine: { model in
                guard let engine = engines.makeEngine(for: model) else { throw WhisperEngineError.notReady }
                return engine
            },
            lookup: { await store.verifiedArtifact(for: $0) },
            acquire: { model, consent in
                let result = await store.acquire(model, consent: consent)
                guard result.state == .ready else {
                    throw result.error ?? ModelAcquisitionError.downloadFailed("acquisition did not verify")
                }
            }, freeBytes: { await ModelReadinessStore.freeDiskSpace() })
    }

    func isCurrent(_ value: PreparedEngine) -> Bool {
        generation == value.generation && request == value.request && prepared?.token == value.token && phase == .ready
    }

    func prepare(_ requested: EnginePreparationRequest, retry: Bool = false) async -> PreparedEngine? {
        guard !Task.isCancelled else { return nil }
        if request != requested || generation == nil || retry || phase == .cancelled {
            invalidate()
            request = requested
            generation = UUID()
            phase = .queued
        }
        if prepared != nil, phase == .ready {
            // Even a cached engine's actor getters can suspend. Validate it in
            // the retained worker, not in this caller's cancellation path.
            phase = .queued
        }
        guard let id = generation, phase.isBusy else { return nil }
        let waiterID = UUID()
        let (stream, continuation) = AsyncStream<PreparedEngine>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[waiterID] = continuation
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self] in self?.removeWaiter(waiterID, generation: id) }
        }
        startQueuedWork()
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        // AsyncStream cancellation wakes this caller immediately. There is no
        // task-group scope or task.value join waiting for uncooperative I/O.
        if Task.isCancelled {
            removeWaiter(waiterID, generation: id)
            return nil
        }
        guard let value, isCurrent(value) else { return nil }
        return value
    }

    func cancel() {
        invalidate()
        phase = .cancelled
    }

    private func invalidate() {
        generation = nil
        prepared = nil
        for worker in workers.values { worker.task.cancel() }
        finishWaiters()
    }

    private func removeWaiter(_ waiterID: UUID, generation id: UUID) {
        guard generation == id else { return }
        waiters.removeValue(forKey: waiterID)?.finish()
        if waiters.isEmpty, phase.isBusy { cancel() }
    }

    private func finishWaiters(with value: PreparedEngine? = nil) {
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            if let value { continuation.yield(value) }
            continuation.finish()
        }
    }

    private func startQueuedWork() {
        guard let request, let id = generation, !waiters.isEmpty, phase.isBusy else { return }
        let kind = request.model.isWhisperKit
        guard workers[kind] == nil else { return }
        let task = Task { await run(request, generation: id) }
        workers[kind] = (id, task)
    }

    private func requireCurrent(_ id: UUID) throws {
        guard generation == id, !Task.isCancelled else { throw CancellationError() }
    }

    private func run(_ request: EnginePreparationRequest, generation id: UUID) async {
        let kind = request.model.isWhisperKit
        defer {
            if workers[kind]?.id == id { workers[kind] = nil }
            startQueuedWork()
        }
        do {
            try requireCurrent(id)
            if let cached = prepared {
                let ready = await cached.engine.isReady
                let quarantined = await cached.engine.isQuarantined
                try requireCurrent(id)
                if ready && !quarantined {
                    try await cached.engine.preflight(localOnly: request.localOnly, language: request.language)
                    try requireCurrent(id)
                    phase = .ready
                    finishWaiters(with: cached)
                    return
                }
                prepared = nil
            }
            var artifact: Artifact?
            if kind {
                phase = .verifying
                artifact = await lookup(request.model)
                try requireCurrent(id)
                if artifact == nil {
                    guard request.allowDownloads else {
                        phase = .consentRequired
                        finishWaiters()
                        return
                    }
                    let available = await freeBytes()
                    try requireCurrent(id)
                    guard
                        ModelUIPolicy.mayStartDownload(
                            consent: true, hasCachedVerifiedModel: false, freeBytes: available) == .allowed
                    else {
                        phase = .insufficientSpace
                        finishWaiters()
                        return
                    }
                    phase = .acquiring
                    try await acquire(request.model, request.allowDownloads)
                    try requireCurrent(id)
                    phase = .verifying
                    artifact = await lookup(request.model)
                    try requireCurrent(id)
                }
                guard artifact != nil else { throw WhisperEngineError.notReady }
            }
            let engine = try makeEngine(request.model)
            phase = .loading
            try await engine.load(model: request.model, verifiedFolder: artifact?.folder.path)
            try requireCurrent(id)
            try await engine.preflight(localOnly: request.localOnly, language: request.language)
            try requireCurrent(id)
            await engine.recordVerifiedDigest(artifact?.aggregateDigest)
            let ready = await engine.isReady
            let quarantined = await engine.isQuarantined
            try requireCurrent(id)
            guard ready && !quarantined else { throw WhisperEngineError.notReady }
            let value = PreparedEngine(generation: id, request: request, engine: engine, token: EngineToken())
            prepared = value
            phase = .ready
            finishWaiters(with: value)
        } catch {
            guard generation == id else { return }
            if let failure = error as? SpeechCapabilityFailure {
                phase = .unavailable(failure)
            } else {
                phase = error is CancellationError ? .cancelled : .failed
            }
            finishWaiters()
        }
    }
}
