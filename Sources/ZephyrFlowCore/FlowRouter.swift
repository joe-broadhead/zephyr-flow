import Foundation

/// Routes Flow styles to regex and/or optional neural backend with deadline + guardrails.
public actor FlowRouter: FlowProcessorProtocol {
    public static let shared = FlowRouter()

    private let regex: any FlowProcessorProtocol
    private var neural: (any FlowProcessorProtocol)?
    private var backendProvider: @Sendable () async -> FlowBackend = { .regex }
    private var neuralReadyProvider: @Sendable () async -> Bool = { false }

    /// Styles that may use neural under neural/auto backends.
    public static let neuralEligible: Set<FlowStyle> = [.professional, .summary, .bullets]

    /// Soft deadline for neural rewrite (protects sessionChain).
    public var neuralTimeoutNanoseconds: UInt64 = 1_000_000_000

    public init(regex: any FlowProcessorProtocol = FlowProcessor.shared) {
        self.regex = regex
    }

    public func configure(
        backend: @escaping @Sendable () async -> FlowBackend,
        neuralReady: @escaping @Sendable () async -> Bool,
        neural: (any FlowProcessorProtocol)?
    ) {
        self.backendProvider = backend
        self.neuralReadyProvider = neuralReady
        self.neural = neural
    }

    public func setNeural(_ processor: (any FlowProcessorProtocol)?) {
        self.neural = processor
    }

    public func process(_ text: String, style: FlowStyle) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let backend = await backendProvider()
        let ready = await neuralReadyProvider()
        let eligible = Self.neuralEligible.contains(style)
        let wantNeural =
            eligible
            && ready
            && (backend == .neural || backend == .auto)
            && neural != nil

        guard wantNeural, let neural else {
            return await regex.process(text, style: style)
        }

        let timeout = neuralTimeoutNanoseconds
        let neuralResult: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await neural.process(text, style: style)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return nil
            }
            var first: String?
            for await value in group {
                if let value {
                    first = value
                    group.cancelAll()
                    break
                } else {
                    // timeout
                    group.cancelAll()
                    break
                }
            }
            return first
        }

        if let neuralResult,
           let accepted = FlowGuardrails.accept(input: trimmed, output: neuralResult) {
            return accepted
        }

        return await regex.process(text, style: style)
    }
}
