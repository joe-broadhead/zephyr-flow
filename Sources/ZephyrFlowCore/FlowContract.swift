import Foundation

/// FlowLossClass: the semantic-loss boundary for every Flow style
/// (contract: JOE-2275). Reigns from least to most lossy.
public enum FlowLossClass: String, Codable, CaseIterable, Sendable, Equatable {
    /// Trim/line-ending normalisation only. No other change.
    case verbatim
    /// Whitespace, punctuation and narrowly approved fillers; nothing
    /// structural or semantic.
    case conservative
    /// Paragraph/bullet formatting while preserving all propositions and
    /// every protected span.
    case structural
    /// Summary/professional rewrite with explicit higher-risk consent and
    /// measured budgets (never the default).
    case semantic

    /// Whether the class may run on secure/unknown sessions: only the
    /// conservative/verbatim path is ever allowed (JOE-2275).
    public var allowedForSecureSessions: Bool {
        switch self {
        case .verbatim, .conservative: return true
        case .structural, .semantic: return false
        }
    }

    /// Whether the class requires explicit user consent beyond normal use.
    public var requiresExplicitConsent: Bool {
        self == .semantic
    }
}

/// The protected-span grammar: span kinds that must survive unchanged or
/// cause conservative fallback (JOE-2275). Extraction/canonicalisation are
/// versioned pure functions (implementation JOE-2277/2278).
public enum ProtectedSpanKind: String, Codable, CaseIterable, Sendable, Equatable {
    case signedNumber
    case decimalNumber
    case groupedNumber
    case currency
    case percentage
    case unit
    case date
    case time
    case duration
    case version
    case negation
    case modalConstraint
    case url
    case email
    case filePath
    case codeSpan
    case quote
    case identifier       // issue/commit ids, product/proper names
    case paragraphBreak
    case listBoundary
}

/// A typed protected span with source range and canonical form.
public struct ProtectedSpan: Sendable, Equatable {
    public let kind: ProtectedSpanKind
    /// Character range in the source text.
    public let sourceRange: Range<Int>
    /// Canonical token used for preservation comparison. Never the raw text
    /// when a redacted canonical form exists.
    public let canonical: String
    /// Multiplicity/order/association guard marker: identical canonical
    /// tokens from different ranges must stay distinct.
    public let instance: UInt64

    public init(kind: ProtectedSpanKind, sourceRange: Range<Int>, canonical: String, instance: UInt64) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.canonical = canonical
        self.instance = instance
    }
}

/// HostLanguage: language metadata that gate Flow transformations
/// (JOE-2275/2277). Non-English text never receives English rewrites.
public struct FlowLanguageContext: Sendable, Equatable {
    /// BCP-47 primary tag, e.g. "en", "de"; "auto" means detected.
    public let language: String
    /// When true the rules run in conservative mode regardless of style.
    public let forceConservative: Bool

    public init(language: String, forceConservative: Bool = false) {
        self.language = language
        self.forceConservative = forceConservative
    }

    public var isEnglishQualified: Bool {
        language.lowercased().hasPrefix("en") && !forceConservative
    }
}


// MARK: - JOE-2279 typed Flow outcome

/// Context for a Flow transformation (session, sensitivity, cancellation).
public struct FlowRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let text: String
    public let style: FlowStyle
    public let language: SupportedLanguage
    public let sensitivity: SessionSensitivity
    /// Hard deadline; a non-cooperative backend must never block past it and
    /// a late result must never overwrite the fallback.
    public let deadlineNanosAhead: UInt64

    public init(sessionID: SessionID, text: String, style: FlowStyle,
                language: SupportedLanguage, sensitivity: SessionSensitivity,
                deadlineNanosAhead: UInt64 = 2_000_000_000) {
        self.sessionID = sessionID
        self.text = text
        self.style = style
        self.language = language
        self.sensitivity = sensitivity
        self.deadlineNanosAhead = deadlineNanosAhead
    }
}

public enum FlowOutcomeStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case accepted
    case rejected            // guardrails rejected; fallback returned
    case deadlineExceeded    // backend exceeded deadline; fallback returned
    case cancelled
    case superseded          // produced after session superseded
}

public enum FlowOutcomeTermination: String, Codable, CaseIterable, Sendable, Equatable {
    case completed
    case cancelled
    case deadlineExceeded
    case superseded
}

public enum FlowWarning: String, Codable, CaseIterable, Sendable, Equatable {
    case guardrailRejected
    case backendUnavailable
    case secureSensitivityConservative
    case structuralFallback
    case enhancedTimeout
    case lateResultIgnored
}

/// Typed Flow outcome: transformation risk, actual changes, fallback and
/// timing are visible to policy, UI and evidence systems (JOE-2279).
public struct FlowOutcome: Sendable, Equatable {
    public let text: String
    public let requestedStyle: FlowStyle
    public let resolvedLossClass: FlowLossClass
    public let backend: FlowBackend
    public let capabilityID: String
    public let capabilityVersion: Int
    public let language: SupportedLanguage
    /// Structured diff summary — counts only (never changed text).
    public let changedRangeCount: Int
    public let protectedSpanCount: Int
    public let protectedSpansPreserved: Bool
    public let status: FlowOutcomeStatus
    public let warnings: [FlowWarning]
    public let fallbackReason: String?
    public let durationNanos: UInt64
    public let termination: FlowOutcomeTermination

    public init(text: String, requestedStyle: FlowStyle, resolvedLossClass: FlowLossClass,
                backend: FlowBackend, capabilityID: String, capabilityVersion: Int,
                language: SupportedLanguage, changedRangeCount: Int,
                protectedSpanCount: Int, protectedSpansPreserved: Bool,
                status: FlowOutcomeStatus, warnings: [FlowWarning],
                fallbackReason: String?, durationNanos: UInt64,
                termination: FlowOutcomeTermination) {
        self.text = text
        self.requestedStyle = requestedStyle
        self.resolvedLossClass = resolvedLossClass
        self.backend = backend
        self.capabilityID = capabilityID
        self.capabilityVersion = capabilityVersion
        self.language = language
        self.changedRangeCount = changedRangeCount
        self.protectedSpanCount = protectedSpanCount
        self.protectedSpansPreserved = protectedSpansPreserved
        self.status = status
        self.warnings = warnings
        self.fallbackReason = fallbackReason
        self.durationNanos = durationNanos
        self.termination = termination
    }

    /// The safe fallback is an explicit outcome, not indistinguishable from
    /// normal backend success.
    public var usedFallback: Bool {
        status != .accepted || !warnings.isEmpty
    }

    /// Diagnostic serialization: redacts text and content-bearing ranges.
    public var diagnostics: FlowOutcomeDiagnostics {
        FlowOutcomeDiagnostics(requestedStyle: requestedStyle,
                               resolvedLossClass: resolvedLossClass,
                               backend: backend,
                               capabilityID: capabilityID,
                               capabilityVersion: capabilityVersion,
                               language: language,
                               changedRangeCount: changedRangeCount,
                               protectedSpanCount: protectedSpanCount,
                               protectedSpansPreserved: protectedSpansPreserved,
                               status: status,
                               warnings: warnings,
                               fallbackReason: fallbackReason,
                               durationNanos: durationNanos,
                               termination: termination)
    }

    public static func lossClass(for style: FlowStyle) -> FlowLossClass {
        switch style {
        case .raw: return .verbatim
        case .clean: return .conservative
        case .bullets: return .structural
        case .professional: return .semantic
        case .summary: return .semantic
        }
    }
}

/// Content-free diagnostics view of a FlowOutcome.
public struct FlowOutcomeDiagnostics: Sendable, Equatable {
    public let requestedStyle: FlowStyle
    public let resolvedLossClass: FlowLossClass
    public let backend: FlowBackend
    public let capabilityID: String
    public let capabilityVersion: Int
    public let language: SupportedLanguage
    public let changedRangeCount: Int
    public let protectedSpanCount: Int
    public let protectedSpansPreserved: Bool
    public let status: FlowOutcomeStatus
    public let warnings: [FlowWarning]
    public let fallbackReason: String?
    public let durationNanos: UInt64
    public let termination: FlowOutcomeTermination
}
