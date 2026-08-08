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
