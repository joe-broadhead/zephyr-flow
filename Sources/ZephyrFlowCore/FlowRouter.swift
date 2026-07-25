import Foundation

/// Routes Flow styles to regex and/or optional enhanced backend with deadline + guardrails.
public actor FlowRouter: FlowProcessorProtocol {
    public static let shared = FlowRouter()

    private let regex: any FlowProcessorProtocol
    private var enhanced: (any FlowProcessorProtocol)?
    private var backendProvider: @Sendable () async -> FlowBackend = { .regex }
    private var enhancedReadyProvider: @Sendable () async -> Bool = { false }

    public static let enhancedEligible: Set<FlowStyle> = [.professional, .summary, .bullets]

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

    /// App wiring alias (historical name).
    public func configure(
        backend: @escaping @Sendable () async -> FlowBackend,
        neuralReady: @escaping @Sendable () async -> Bool,
        neural: (any FlowProcessorProtocol)?
    ) {
        configure(backend: backend, enhancedReady: neuralReady, enhanced: neural)
    }

    public func process(_ text: String, style: FlowStyle) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let backend = await backendProvider()
        let ready = await enhancedReadyProvider()
        let eligible = Self.enhancedEligible.contains(style)
        // Accept legacy `.neural` raw value as enhanced.
        let wantEnhanced =
            eligible
            && ready
            && (backend == .enhanced || backend == .auto || backend == .neural)
            && enhanced != nil

        guard wantEnhanced, let enhanced else {
            return await regex.process(text, style: style)
        }

        let timeout = enhancedTimeoutNanoseconds
        let outcome: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let value = await enhanced.process(text, style: style)
                if Task.isCancelled { return nil }
                return value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }

            // First finished child wins. Cancel the other.
            // Enhanced path must honor cancellation so the group can unwind quickly.
            var winner: String??
            for await value in group {
                winner = value
                group.cancelAll()
                break
            }
            return winner ?? nil
        }

        if let outcome, let accepted = FlowGuardrails.accept(input: trimmed, output: outcome) {
            return accepted
        }
        return await regex.process(text, style: style)
    }
}
