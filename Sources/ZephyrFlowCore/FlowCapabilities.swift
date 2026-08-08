import Foundation

/// FlowCapability (JOE-2276): explicit, machine-verifiable contract of what a
/// Flow backend can do. A future semantic/model backend must declare its own
/// capability and be admitted through a distinct capability + evidence gate —
/// it can never masquerade as this deterministic rules backend because the
/// capability id and the `deterministic && !requiresModelWeights &&
/// network == .none` triple are part of this type (equality is id-scoped).
public struct FlowCapability: Sendable, Equatable {
    /// Stable identity of this backend contract. A different id is a
    /// different capability, even with equal lookup fields.
    public let id: String
    public let version: String
    public let networkUse: FlowBackendNetworkUse
    public let requiresModelWeights: Bool
    public let isDeterministic: Bool
    /// Styles the backend can produce (including passthrough styles).
    public let styles: Set<FlowStyle>
    /// Styles actually enhanced beyond regex passthrough.
    public let enhancedStyles: Set<FlowStyle>
    /// Loss classes the backend preserves across transformation (JOE-2275).
    public let lossClasses: Set<FlowLossClass>
    /// Languages with first-class rule handling; other locales get
    /// conservative regex passthrough only.
    public let languages: Set<String>
    public let cancellation: FlowBackendCancellation
    public let resourceRequirement: FlowResourceRequirement
    public let entryGate: FlowBackendEntryGate

    public init(id: String,
                version: String,
                networkUse: FlowBackendNetworkUse,
                requiresModelWeights: Bool,
                isDeterministic: Bool,
                styles: Set<FlowStyle>,
                enhancedStyles: Set<FlowStyle>,
                lossClasses: Set<FlowLossClass>,
                languages: Set<String>,
                cancellation: FlowBackendCancellation,
                resourceRequirement: FlowResourceRequirement,
                entryGate: FlowBackendEntryGate = .deterministicRules) {
        self.id = id
        self.version = version
        self.networkUse = networkUse
        self.requiresModelWeights = requiresModelWeights
        self.isDeterministic = isDeterministic
        self.styles = styles
        self.enhancedStyles = enhancedStyles
        self.lossClasses = lossClasses
        self.languages = languages
        self.cancellation = cancellation
        self.resourceRequirement = resourceRequirement
        self.entryGate = entryGate
    }

    /// Canonical identity of the deterministic rules backend.
    public static let rulesCapabilityId = "io.zephyr-flow.flow.rules.v1"

    /// Deterministic rules backend capability (measured; no RAM gate).
    public static let enhancedRules = FlowCapability(
        id: rulesCapabilityId,
        version: "1.0",
        networkUse: .none,
        requiresModelWeights: false,
        isDeterministic: true,
        styles: [.clean, .bullets, .professional, .summary, .raw],
        enhancedStyles: [.bullets, .professional, .summary],
        lossClasses: Set(FlowLossClass.allCases),
        languages: ["en"],
        cancellation: .cooperative,
        resourceRequirement: .required(megabytes: 32)
    )

    /// True only for the single canonical rules identity. A semantic backend
    /// (LLM/cloud/weights) reports a different id and fails here.
    public var isRulesCompatible: Bool { id == Self.rulesCapabilityId }

    /// The deterministic-rules triple gate used by routing code.
    public var passesRulesGate: Bool {
        isRulesCompatible && isDeterministic && !requiresModelWeights && networkUse == .none
    }

    /// Capability-driven style eligibility (no scattered backend checks).
    public func eligibility(for style: FlowStyle) -> StyleEligibility {
        if !styles.contains(style) { return .notSupportedByBackend }
        if enhancedStyles.contains(style) { return .enhancedEligible }
        return .passthroughOnly
    }
}

public enum StyleEligibility: Sendable, Equatable {
    case enhancedEligible
    case passthroughOnly
    case notSupportedByBackend
}

public enum FlowBackendNetworkUse: String, Sendable, Equatable {
    case none
    case onDeviceDownloadsOnly
    case online
}

public enum FlowBackendCancellation: String, Sendable, Equatable {
    /// Cooperative: the backend checks Task.isCancelled between passes.
    case cooperative
}

public enum FlowResourceRequirement: Sendable, Equatable {
    case none
    case required(megabytes: Int)
}

public enum FlowBackendEntryGate: String, Sendable, Equatable {
    /// Deterministic rules: no extra gate.
    case deterministicRules
    /// Any future semantic/model backend must pass a capability and
    /// evidence gate before it can be selected.
    case semanticModelRequiresEvidence
}
