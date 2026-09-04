import Foundation

/// Routes Flow styles to regex and/or optional enhanced backend with deadline + guardrails.
public actor FlowRouter: FlowProcessorProtocol {
    public static let shared = FlowRouter()

    private let regex: any FlowProcessorProtocol
    private var enhanced: (any FlowProcessorProtocol)?
    private var backendProvider: @Sendable () async -> FlowBackend = { .regex }
    private var enhancedReadyProvider: @Sendable () async -> Bool = { false }

    /// Soft deadline for enhanced rewrite (protects sessionChain).
    public var enhancedTimeoutNanoseconds: UInt64 = 1_000_000_000

    public init(regex: any FlowProcessorProtocol = FlowProcessor.shared) {
        self.regex = regex
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

    public func process(_ text: String, style: FlowStyle) async -> String {
        await process(text, style: style, language: .auto)
    }

    /// JOE-2279: typed outcome with deadline, supersession and explicit
    /// fallback; a late backend result can never overwrite the fallback.
    public func process(_ request: FlowRequest) async -> FlowOutcome {
        let t0 = DispatchTime.now().uptimeNanoseconds
        // Sensitivity/capability policy rejects BEFORE execution: secure/
        // unknown sessions only ever get conservative/verbatim classes.
        let loss = FlowOutcome.lossClass(for: request.style)
        if !loss.allowedForSecureSessions && !request.sensitivity.allowsAutomaticSideEffects {
            let conservative = await process(
                request.text, style: .clean,
                language: request.language)
            return FlowOutcome(
                text: conservative,
                requestedStyle: request.style,
                resolvedLossClass: .conservative,
                backend: .regex,
                capabilityID: "io.zephyr-flow.flow.rules.v1",
                capabilityVersion: 1,
                language: request.language,
                changedRangeCount: 1,
                protectedSpanCount: FlowGuardrails.tokens(in: request.text).count,
                protectedSpansPreserved: true,
                status: .accepted,
                warnings: [.secureSensitivityConservative],
                fallbackReason: "secure sensitivity: conservative class only",
                durationNanos: DispatchTime.now().uptimeNanoseconds &- t0,
                termination: .completed)
        }

        let backend = await backendProvider()
        let ready = await enhancedReadyProvider()
        let isLegacyNeural = backend.rawValue == "neural"
        let eligible = FlowCapability.enhancedRules.eligibility(for: request.style) == .enhancedEligible
        let rulesReady = ready && FlowCapability.enhancedRules.passesRulesGate
        let wantEnhanced =
            eligible
            && rulesReady
            && (backend == .enhanced || backend == .auto || isLegacyNeural)
            && enhanced != nil

        guard wantEnhanced, let enhanced else {
            let out = await regex.process(request)
            return FlowOutcome(
                text: out.text,
                requestedStyle: request.style,
                resolvedLossClass: out.resolvedLossClass,
                backend: out.backend,
                capabilityID: out.capabilityID,
                capabilityVersion: out.capabilityVersion,
                language: request.language,
                changedRangeCount: out.changedRangeCount,
                protectedSpanCount: out.protectedSpanCount,
                protectedSpansPreserved: out.protectedSpansPreserved,
                status: out.status,
                warnings: out.warnings + (wantEnhanced ? [] : [.backendUnavailable]),
                fallbackReason: out.fallbackReason ?? (wantEnhanced ? nil : "enhanced backend unavailable"),
                durationNanos: out.durationNanos,
                termination: out.termination)
        }

        // Deadline-bounded enhanced call; late results are dropped.
        let timeout = enhancedTimeoutNanoseconds
        let fallback = await regex.process(request)
        let outcome: FlowOutcome? = await withTaskGroup(of: FlowOutcome?.self) { group in
            group.addTask {
                let value = await enhanced.process(request)
                if Task.isCancelled { return nil }
                return value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let enhancedOutcome = outcome else {
            // Deadline: fallback is explicit, never overwritten by a late
            // result (the group dropped it).
            return FlowOutcome(
                text: fallback.text,
                requestedStyle: request.style,
                resolvedLossClass: fallback.resolvedLossClass,
                backend: fallback.backend,
                capabilityID: fallback.capabilityID,
                capabilityVersion: fallback.capabilityVersion,
                language: request.language,
                changedRangeCount: fallback.changedRangeCount,
                protectedSpanCount: fallback.protectedSpanCount,
                protectedSpansPreserved: fallback.protectedSpansPreserved,
                status: .deadlineExceeded,
                warnings: [.enhancedTimeout, .lateResultIgnored],
                fallbackReason: "enhanced backend exceeded deadline; late result ignored",
                durationNanos: DispatchTime.now().uptimeNanoseconds &- t0,
                termination: .deadlineExceeded)
        }
        // Enhanced outcome passed through (guardrails visible inside it).
        return FlowOutcome(
            text: enhancedOutcome.text,
            requestedStyle: request.style,
            resolvedLossClass: enhancedOutcome.resolvedLossClass,
            backend: enhancedOutcome.backend,
            capabilityID: enhancedOutcome.capabilityID,
            capabilityVersion: enhancedOutcome.capabilityVersion,
            language: request.language,
            changedRangeCount: enhancedOutcome.changedRangeCount,
            protectedSpanCount: enhancedOutcome.protectedSpanCount,
            protectedSpansPreserved: enhancedOutcome.protectedSpansPreserved,
            status: enhancedOutcome.status,
            warnings: enhancedOutcome.warnings,
            fallbackReason: enhancedOutcome.fallbackReason,
            durationNanos: DispatchTime.now().uptimeNanoseconds &- t0,
            termination: enhancedOutcome.termination)
    }

    /// JOE-2277: language-aware routing (regex + enhanced backends) with the
    /// JOE-2276 capability eligibility + enhanced timeout guardrails.
    public func process(_ text: String, style: FlowStyle, language: SupportedLanguage) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let backend = await backendProvider()
        let ready = await enhancedReadyProvider()
        let isLegacyNeural = backend.rawValue == "neural"
        let eligible = FlowCapability.enhancedRules.eligibility(for: style) == .enhancedEligible
        let rulesReady = ready && FlowCapability.enhancedRules.passesRulesGate
        let wantEnhanced =
            eligible
            && rulesReady
            && (backend == .enhanced || backend == .auto || isLegacyNeural)
            && enhanced != nil

        guard wantEnhanced, let enhanced else {
            return await regex.process(text, style: style, language: language)
        }

        let timeout = enhancedTimeoutNanoseconds
        let outcome: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let value = await enhanced.process(text, style: style, language: language)
                if Task.isCancelled { return nil }
                return value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let outcome {
            return outcome
        }
        return await regex.process(text, style: style, language: language)
    }
}
