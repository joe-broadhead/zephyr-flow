import Foundation

// JOE-2254: validated language selection + on-device capability checks.
//
// Replaces free-form language storage with a validated model (`auto` +
// supported BCP-47 identifiers), threads the selection into every engine,
// preflights on-device support (Local Only never falls back to network), and
// documents the fallback policy explicitly (never silent substitution).

/// Validated language selection. `auto` = engine auto-detection; otherwise a
/// supported BCP-47 identifier.
public enum SupportedLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case enUS = "en-US"
    case enGB = "en-GB"
    case deDE = "de-DE"
    case frFR = "fr-FR"
    case esES = "es-ES"
    case itIT = "it-IT"
    case ptBR = "pt-BR"
    case jaJP = "ja-JP"
    case zhCN = "zh-CN"
    case koKR = "ko-KR"
    case nlNL = "nl-NL"
    case ruRU = "ru-RU"
    case svSE = "sv-SE"
    case daDK = "da-DK"
    case nbNO = "nb-NO"
    case fiFI = "fi-FI"
    case plPL = "pl-PL"
    case trTR = "tr-TR"
    case hiIN = "hi-IN"
    case arSA = "ar-SA"

    public var id: String { rawValue }

    /// BCP-47 identifier for engine configuration (nil = auto-detect).
    public var bcp47: String? {
        switch self {
        case .auto: return nil
        default: return rawValue
        }
    }

    public var isAuto: Bool { self == .auto }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        default:
            let locale = Locale(identifier: rawValue)
            let name = locale.localizedString(forIdentifier: rawValue) ?? rawValue
            return name.capitalized
        }
    }

    /// Migration from the legacy free-form String field.
    public static func fromLegacy(_ value: String) -> SupportedLanguage {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return .auto
        }
        return SupportedLanguage(rawValue: trimmed) ?? .auto
    }
}

/// Deterministic capability decision for one language × engine pair.
public enum LanguageCapabilityDecision: String, Codable, CaseIterable, Sendable, Equatable {
    /// Engine supports the requested language on-device.
    case supported
    /// Engine/language combination is unsupported — actionable failure, never
    /// a silent substitution.
    case unavailable
    /// Requested `auto`: engine auto-detection is allowed.
    case autoDetection
}

/// Content-free capability record for the language matrix.
public struct LanguageCapability: Sendable, Equatable {
    public let language: SupportedLanguage
    public let whisperOnDevice: Bool
    public let appleOnDevice: Bool
    public let appleAvailable: Bool
    /// Actionable message when a language pack is missing (Local Only).
    public let missingPackMessage: String?

    public init(language: SupportedLanguage,
                whisperOnDevice: Bool,
                appleOnDevice: Bool,
                appleAvailable: Bool,
                missingPackMessage: String?) {
        self.language = language
        self.whisperOnDevice = whisperOnDevice
        self.appleOnDevice = appleOnDevice
        self.appleAvailable = appleAvailable
        self.missingPackMessage = missingPackMessage
    }

    public func decision(for engine: EngineKind) -> LanguageCapabilityDecision {
        switch language {
        case .auto:
            return .autoDetection
        default:
            switch engine {
            case .whisper:
                return whisperOnDevice ? .supported : .unavailable
            case .appleSpeech:
                if !appleAvailable { return .unavailable }
                return appleOnDevice ? .supported : .unavailable
            }
        }
    }
}
