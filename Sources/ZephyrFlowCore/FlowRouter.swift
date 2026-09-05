import Foundation

/// Typed routing with bounded callers and retained ownership of outstanding
/// work. Cancellation/deadline is not native completion. One uncooperative
/// backend can retain one request, but cannot spawn an unbounded worker queue
/// or publish into a later request. No payload is logged.
public actor FlowRouter: FlowProcessorProtocol {
    public static let shared = FlowRouter()
    private let regex: any FlowProcessorProtocol
    private var enhanced: (any FlowProcessorProtocol)?
    private var backendProvider: @Sendable () async -> FlowBackend = { .regex }
    private var enhancedReadyProvider: @Sendable () async -> Bool = { false }
    public var enhancedTimeoutNanoseconds: UInt64 = 1_000_000_000

    private struct Work {
        let id: UUID
        let task: Task<Void, Never>
        let completion: AsyncStream<FlowOutcome>.Continuation
    }
    private var work: Work?
    /// Content-free ownership diagnostic; true until native work really exits.
    public var hasOutstandingWork: Bool { work != nil }

    public init(
        regex: any FlowProcessorProtocol = FlowProcessor.shared, enhancedTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.regex = regex
        self.enhancedTimeoutNanoseconds = enhancedTimeoutNanoseconds
    }

    public func configure(
        backend: @escaping @Sendable () async -> FlowBackend,
        enhancedReady: @escaping @Sendable () async -> Bool,
        enhanced: (any FlowProcessorProtocol)?
    ) {
        self.backendProvider = backend
        self.enhancedReadyProvider = enhancedReady
        self.enhanced = enhanced
    }

    public func process(_ request: FlowRequest) async -> FlowOutcome {
        let clock = ContinuousClock()
        let started = clock.now
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let deadline = started.advanced(by: .nanoseconds(Int64(clamping: request.deadlineNanosAhead)))
        if Task.isCancelled { return fallback(request, start: startNanos, reason: .cancelled) }
        guard request.deadlineNanosAhead > 0 else { return fallback(request, start: startNanos, reason: .deadline) }
        guard work == nil else { return fallback(request, start: startNanos, reason: .busy) }

        let id = UUID()
        let (stream, completion) = AsyncStream.makeStream(of: FlowOutcome.self, bufferingPolicy: .bufferingNewest(1))
        // Snapshot configuration for this request; later settings changes apply
        // to the next request only. Even a held settings provider is bounded.
        let selectBackend = backendProvider
        let isEnhancedReady = enhancedReadyProvider
        let selectedEnhanced = enhanced
        let enhancedTimeout = enhancedTimeoutNanoseconds
        let worker = Task {
            let outcome = await self.route(
                request, start: startNanos, completion: completion,
                selectBackend: selectBackend, isEnhancedReady: isEnhancedReady,
                enhanced: selectedEnhanced, enhancedTimeout: enhancedTimeout)
            self.complete(id: id, outcome: outcome)
        }
        work = Work(id: id, task: worker, completion: completion)
        let timer = Task {
            do { try await clock.sleep(until: deadline) } catch { return }
            completion.finish()
        }
        let outcome: FlowOutcome? = await withTaskCancellationHandler {
            for await value in stream { return value }
            return nil
        } onCancel: {
            completion.finish()
            worker.cancel()
        }
        timer.cancel()
        completion.finish()
        // Do not join an uncooperative worker. Its registry entry is released
        // only by complete(), never by caller timeout or cancellation.
        if Task.isCancelled {
            worker.cancel()
            return fallback(request, start: startNanos, reason: .cancelled)
        }
        if clock.now >= deadline || outcome == nil {
            worker.cancel()
            return fallback(request, start: startNanos, reason: .deadline)
        }
        if outcome?.termination == .deadlineExceeded { worker.cancel() }
        return outcome ?? fallback(request, start: startNanos, reason: .deadline)
    }

    private func complete(id: UUID, outcome: FlowOutcome) {
        guard let active = work, active.id == id else { return }
        if !Task.isCancelled { active.completion.yield(outcome) }
        active.completion.finish()
        work = nil
    }

    private func route(
        _ request: FlowRequest, start: UInt64, completion: AsyncStream<FlowOutcome>.Continuation,
        selectBackend: @Sendable () async -> FlowBackend, isEnhancedReady: @Sendable () async -> Bool,
        enhanced: (any FlowProcessorProtocol)?, enhancedTimeout: UInt64
    ) async -> FlowOutcome {
        if Task.isCancelled { return fallback(request, start: start, reason: .cancelled) }
        let sensitiveDowngrade =
            !FlowOutcome.lossClass(for: request.style).allowedForSecureSessions
            && !request.sensitivity.allowsAutomaticSideEffects
        if sensitiveDowngrade {
            let conservative = FlowRequest(
                sessionID: request.sessionID, text: request.text, style: .clean,
                language: request.language, sensitivity: request.sensitivity,
                deadlineNanosAhead: request.deadlineNanosAhead)
            let output = await regex.process(conservative)
            return projected(
                output, request: request, start: start,
                warnings: [.secureSensitivityConservative], reason: "secure sensitivity: conservative class only")
        }

        let backend = await selectBackend()
        if Task.isCancelled { return fallback(request, start: start, reason: .cancelled) }
        let eligible = FlowCapability.enhancedRules.eligibility(for: request.style) == .enhancedEligible
        let requestedEnhanced = eligible && (backend == .enhanced || backend == .auto || backend.rawValue == "neural")
        var available = false
        if requestedEnhanced, enhanced != nil {
            available = await isEnhancedReady() && FlowCapability.enhancedRules.passesRulesGate
        }
        if Task.isCancelled { return fallback(request, start: start, reason: .cancelled) }
        guard requestedEnhanced, available, let enhanced else {
            let output = await regex.process(request)
            return projected(
                output, request: request, start: start,
                warnings: requestedEnhanced ? [.backendUnavailable] : [],
                reason: requestedEnhanced ? "enhanced backend unavailable" : nil)
        }

        // A soft enhanced timeout can publish an immediate verbatim fallback.
        // It does not wait for either enhanced OR regex work to return first.
        guard enhancedTimeout > 0 else { return fallback(request, start: start, reason: .enhancedDeadline) }
        let softDeadline = ContinuousClock().now.advanced(by: .nanoseconds(Int64(clamping: enhancedTimeout)))
        let softTimer = Task {
            do { try await ContinuousClock().sleep(until: softDeadline) } catch { return }
            completion.yield(self.fallback(request, start: start, reason: .enhancedDeadline))
            completion.finish()
        }
        defer { softTimer.cancel() }
        let output = await enhanced.process(request)
        guard ContinuousClock().now < softDeadline else {
            return fallback(request, start: start, reason: .enhancedDeadline)
        }
        return projected(output, request: request, start: start)
    }

    private enum FallbackReason { case cancelled, deadline, enhancedDeadline, busy }
    private func fallback(_ request: FlowRequest, start: UInt64, reason: FallbackReason) -> FlowOutcome {
        let cancelled = reason == .cancelled
        let deadline = reason == .deadline || reason == .enhancedDeadline
        let message: String
        switch reason {
        case .cancelled: message = "Flow cancelled; original text retained"
        case .deadline: message = "Flow request deadline exceeded; original text retained"
        case .enhancedDeadline: message = "enhanced deadline exceeded; original text retained"
        case .busy: message = "prior Flow work still owns its backend; original text retained"
        }
        return FlowOutcome(
            text: request.text, requestedStyle: request.style, resolvedLossClass: .verbatim,
            backend: .regex, capabilityID: "io.zephyr-flow.flow.verbatim-fallback.v1", capabilityVersion: 1,
            language: request.language, changedRangeCount: 0,
            // No scan is performed in the deadline path. Identity equality
            // guarantees preservation; zero is not a protected-span census.
            protectedSpanCount: 0, protectedSpansPreserved: true,
            status: cancelled ? .cancelled : (deadline ? .deadlineExceeded : .rejected),
            warnings: [.verbatimFallback] + (reason == .enhancedDeadline ? [.enhancedTimeout] : []),
            fallbackReason: message, durationNanos: DispatchTime.now().uptimeNanoseconds &- start,
            termination: cancelled ? .cancelled : (deadline ? .deadlineExceeded : .completed))
    }

    private func projected(
        _ outcome: FlowOutcome, request: FlowRequest, start: UInt64,
        warnings: [FlowWarning] = [], reason: String? = nil
    ) -> FlowOutcome {
        FlowOutcome(
            text: outcome.text, requestedStyle: request.style, resolvedLossClass: outcome.resolvedLossClass,
            backend: outcome.backend, capabilityID: outcome.capabilityID, capabilityVersion: outcome.capabilityVersion,
            language: request.language, changedRangeCount: outcome.changedRangeCount,
            protectedSpanCount: outcome.protectedSpanCount, protectedSpansPreserved: outcome.protectedSpansPreserved,
            status: outcome.status, warnings: outcome.warnings + warnings,
            fallbackReason: outcome.fallbackReason ?? reason,
            durationNanos: DispatchTime.now().uptimeNanoseconds &- start, termination: outcome.termination)
    }

    /// Compatibility callers use the same bounded typed path. Session-domain
    /// production code supplies its actual identity/sensitivity in FlowRequest.
    public func process(_ text: String, style: FlowStyle) async -> String {
        await process(text, style: style, language: .auto)
    }

    public func process(_ text: String, style: FlowStyle, language: SupportedLanguage) async -> String {
        await process(
            FlowRequest(
                sessionID: SessionID(token: "legacy-flow", sequence: 0, createdAtUptimeNanos: 0),
                text: text, style: style, language: language, sensitivity: .normal)
        ).text
    }
}
