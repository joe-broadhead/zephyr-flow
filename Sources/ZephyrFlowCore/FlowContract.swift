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
