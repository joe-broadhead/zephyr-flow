import Foundation

// MARK: - Transcription

public struct PartialTranscription: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let timestamp: Date

    public init(text: String, isFinal: Bool = false, timestamp: Date = Date()) {
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

public struct FinalTranscription: Sendable, Equatable {
    public let rawText: String
    public let processedText: String
    public let duration: TimeInterval
    public let modelUsed: String

    public init(rawText: String, processedText: String, duration: TimeInterval, modelUsed: String) {
        self.rawText = rawText
        self.processedText = processedText
        self.duration = duration
        self.modelUsed = modelUsed
    }
}

// MARK: - Flow

public enum FlowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case clean
    case bullets
    case professional
    case summary
    case raw

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clean: return "Clean"
        case .bullets: return "Bullets"
        case .professional: return "Professional"
        case .summary: return "Summary"
        case .raw: return "Raw"
        }
    }

    public var systemImage: String {
        switch self {
        case .clean: return "sparkles"
        case .bullets: return "list.bullet"
        case .professional: return "briefcase"
        case .summary: return "text.redaction"
        case .raw: return "text.alignleft"
        }
    }
}

// MARK: - Models

public enum ModelIdentifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleSpeech = "apple-speech"
    case whisperTiny = "openai_whisper-tiny"
    case whisperBase = "openai_whisper-base"
    case whisperSmall = "openai_whisper-small"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (Built-in)"
        case .whisperTiny: return "Whisper Tiny"
        case .whisperBase: return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        }
    }

    public var detail: String {
        switch self {
        case .appleSpeech: return "On-device, no download · Fastest startup"
        case .whisperTiny: return "~75 MB · Fast, good quality"
        case .whisperBase: return "~150 MB · Better accuracy"
        case .whisperSmall: return "~500 MB · Best quality"
        }
    }

    public var isWhisperKit: Bool { self != .appleSpeech }
}

// MARK: - Hotkey

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var keyCode: UInt16?
    public var modifiers: UInt
    public var displayName: String
    public var specialKey: SpecialHotkey?

    public enum SpecialHotkey: String, Codable, Sendable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
    }

    public init(keyCode: UInt16?, modifiers: UInt, displayName: String, specialKey: SpecialHotkey?) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
        self.specialKey = specialKey
    }

    /// Fn / Globe hold-to-talk (Wispr Flow style). Requires Accessibility.
    /// Right Option and Control+Space are available in Settings as alternatives.
    public static let `default` = HotkeyConfig(
        keyCode: nil,
        modifiers: 0,
        displayName: "Fn",
        specialKey: .fn
    )

    public static let controlSpace = HotkeyConfig(
        keyCode: 49, // space
        modifiers: 1 << 18, // NSEvent.ModifierFlags.control / CGEventFlags.maskControl
        displayName: "Control + Space",
        specialKey: nil
    )

    public static let fnKey = HotkeyConfig(
        keyCode: nil,
        modifiers: 0,
        displayName: "Fn",
        specialKey: .fn
    )

    public static let rightOption = HotkeyConfig(
        keyCode: nil,
        modifiers: 0,
        displayName: "Right Option (⌥)",
        specialKey: .rightOption
    )
}

// MARK: - Listening Mode

public enum ListeningMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case holdToTalk
    case toggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Toggle"
        }
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: HotkeyConfig
    public var preferredModel: ModelIdentifier
    public var defaultFlowStyle: FlowStyle
    public var language: String
    /// When true (default), user audio/transcripts are not sent off-device (no analytics; Apple Speech fail-closed).
    public var localOnlyMode: Bool
    /// Allows one-time Whisper model file downloads (does not upload audio). Default on so Whisper Tiny works out of the box.
    public var allowModelDownloads: Bool
    public var launchAtLogin: Bool
    public var listeningMode: ListeningMode
    public var hasCompletedOnboarding: Bool
    /// When false, dictations are not written to HistoryStore.
    public var saveHistory: Bool
    /// Verbose hotkey/engine diagnostics written to the local log file.
    public var debugLogging: Bool

    public init(
        hotkey: HotkeyConfig,
        preferredModel: ModelIdentifier,
        defaultFlowStyle: FlowStyle,
        language: String,
        localOnlyMode: Bool,
        allowModelDownloads: Bool = false,
        launchAtLogin: Bool,
        listeningMode: ListeningMode,
        hasCompletedOnboarding: Bool,
        saveHistory: Bool = true,
        debugLogging: Bool = false
    ) {
        self.hotkey = hotkey
        self.preferredModel = preferredModel
        self.defaultFlowStyle = defaultFlowStyle
        self.language = language
        self.localOnlyMode = localOnlyMode
        self.allowModelDownloads = allowModelDownloads
        self.launchAtLogin = launchAtLogin
        self.listeningMode = listeningMode
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.saveHistory = saveHistory
        self.debugLogging = debugLogging
    }

    public static let `default` = AppSettings(
        hotkey: .default,
        preferredModel: .whisperTiny,
        defaultFlowStyle: .clean,
        language: Locale.current.language.languageCode?.identifier ?? "en",
        localOnlyMode: true,
        allowModelDownloads: true,
        launchAtLogin: false,
        listeningMode: .holdToTalk,
        hasCompletedOnboarding: false,
        saveHistory: true,
        debugLogging: false
    )

    /// Model file fetch only — never implies uploading user audio.
    public var mayDownloadModels: Bool {
        allowModelDownloads
    }
}

// MARK: - History

public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let originalText: String
    public let finalText: String
    public let duration: TimeInterval
    public let modelUsed: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        originalText: String,
        finalText: String,
        duration: TimeInterval,
        modelUsed: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalText = originalText
        self.finalText = finalText
        self.duration = duration
        self.modelUsed = modelUsed
    }
}

// MARK: - Insertion

public enum InsertionResult: Sendable, Equatable {
    case inserted
    case pasted
    case copiedToClipboard
    case failed(String)

    public var succeeded: Bool {
        switch self {
        case .inserted, .pasted, .copiedToClipboard: return true
        case .failed: return false
        }
    }

    public var userMessage: String? {
        switch self {
        case .inserted, .pasted: return nil
        case .copiedToClipboard: return "Copied to clipboard"
        case .failed(let msg): return msg
        }
    }
}

// MARK: - Panel State

public enum PanelState: Equatable, Sendable {
    case hidden
    case listening
    case processing
    case success
    case error(String)
}

// MARK: - Permissions

public struct PermissionStatus: Equatable, Sendable {
    public var microphone: Bool
    public var accessibility: Bool
    public var speechRecognition: Bool

    public init(microphone: Bool, accessibility: Bool, speechRecognition: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.speechRecognition = speechRecognition
    }

    public var allGranted: Bool {
        microphone && accessibility && speechRecognition
    }

    public static let unknown = PermissionStatus(
        microphone: false,
        accessibility: false,
        speechRecognition: false
    )
}
