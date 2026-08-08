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

// MARK: - Engine result (JOE-2252)

/// Completeness of a transcription result (controlled taxonomy).
public enum EngineResultCompleteness: String, Codable, CaseIterable, Sendable, Equatable {
    /// Complete: full accepted audio decoded; requires reconciled frame evidence.
    case complete
    /// Rolling partial used (fallback) — never treated as complete.
    case partial
    /// Session was truncated (deadline/cancellation mid-decode).
    case truncated
    /// Degraded capture (overflow/gap/timeout) — fail closed.
    case degraded

    /// Unknown/default values are conservative and can never enable success.
    public var permitsSuccessClaim: Bool { self == .complete }
}

/// How the decode session ended (controlled).
public enum EngineResultTermination: String, Codable, CaseIterable, Sendable, Equatable {
    case completed
    case cancelled
    case deadlineExceeded
    case failed
}

/// Controlled warning (content-free).
public enum EngineWarning: String, Codable, CaseIterable, Sendable, Equatable {
    case partialFallback
    case shortAudioFallback
    case deadlineExceeded
    case truncation
    case captureDegraded
    case lowConfidence
    case engineFallback
}

/// Frame/range accounting attached to a result (JOE-2248 counts, no payloads).
public struct EngineFrameAccounting: Sendable, Equatable {
    public let capturedSourceSamples: UInt64
    public let deliveredEngineSamples: UInt64
    public let decodedEngineSamples: UInt64
    public let droppedSourceSamples: UInt64

    public init(
        capturedSourceSamples: UInt64, deliveredEngineSamples: UInt64,
        decodedEngineSamples: UInt64, droppedSourceSamples: UInt64
    ) {
        self.capturedSourceSamples = capturedSourceSamples
        self.deliveredEngineSamples = deliveredEngineSamples
        self.decodedEngineSamples = decodedEngineSamples
        self.droppedSourceSamples = droppedSourceSamples
    }

    /// Complete results REQUIRE reconciled evidence: delivered (engine-rate)
    /// equals decoded, and captured−dropped equals delivered at the reference
    /// ratio, within the defined rounding tolerance. Missing/zero evidence
    /// cannot enable a completeness claim.
    public func reconciled(
        converterRatio: Double,
        roundingToleranceSamples: UInt64
    ) -> Bool {
        guard capturedSourceSamples > 0 || deliveredEngineSamples > 0 else { return false }
        guard deliveredEngineSamples == decodedEngineSamples else { return false }
        let expected = Double(capturedSourceSamples &- droppedSourceSamples) * converterRatio
        let diff = UInt64(abs(expected - Double(deliveredEngineSamples)))
        return diff <= roundingToleranceSamples
    }
}

/// Engine-neutral result with enough evidence for honest UI, history, metrics
/// and release qualification (JOE-2252). Adapters must NEVER convert a
/// final-decode failure with a rolling partial into `.complete`.
public struct EngineResult: Sendable, Equatable {
    public let text: String
    public let completeness: EngineResultCompleteness
    public let frameAccounting: EngineFrameAccounting?
    /// Engine/model identity (version/digest when available).
    public let engine: EngineIdentity
    public let languageRequested: String?
    public let languageDetected: String?
    public let confidence: Float?
    public let confidenceSource: String?
    /// Timing provenance (monotonic nanoseconds when reliable).
    public let startedAtUptimeNanos: UInt64?
    public let endedAtUptimeNanos: UInt64?
    public let inferenceDurationNanos: UInt64?
    public let warnings: [EngineWarning]
    public let fallbackReason: String?
    public let termination: EngineResultTermination

    public init(
        text: String,
        completeness: EngineResultCompleteness,
        frameAccounting: EngineFrameAccounting?,
        engine: EngineIdentity,
        languageRequested: String?,
        languageDetected: String?,
        confidence: Float?,
        confidenceSource: String?,
        startedAtUptimeNanos: UInt64?,
        endedAtUptimeNanos: UInt64?,
        inferenceDurationNanos: UInt64?,
        warnings: [EngineWarning],
        fallbackReason: String?,
        termination: EngineResultTermination
    ) {
        self.text = text
        self.completeness = completeness
        self.frameAccounting = frameAccounting
        self.engine = engine
        self.languageRequested = languageRequested
        self.languageDetected = languageDetected
        self.confidence = confidence
        self.confidenceSource = confidenceSource
        self.startedAtUptimeNanos = startedAtUptimeNanos
        self.endedAtUptimeNanos = endedAtUptimeNanos
        self.inferenceDurationNanos = inferenceDurationNanos
        self.warnings = warnings
        self.fallbackReason = fallbackReason
        self.termination = termination
    }

    /// Complete results require reconciled frame evidence (conservative).
    public var isComplete: Bool {
        guard completeness == .complete else { return false }
        guard let accounting = frameAccounting else { return false }
        return accounting.reconciled(converterRatio: 1.0, roundingToleranceSamples: 64)
    }

    /// Diagnostics serialization EXCLUDES transcript content by default.
    public var diagnosticsPayload: EngineResultDiagnostics {
        EngineResultDiagnostics(
            completeness: completeness,
            termination: termination,
            engine: engine,
            languageRequested: languageRequested,
            languageDetected: languageDetected,
            confidence: confidence,
            confidenceSource: confidenceSource,
            inferenceDurationNanos: inferenceDurationNanos,
            warnings: warnings,
            fallbackReason: fallbackReason,
            frameAccounting: frameAccounting)
    }
}

/// Content-free diagnostics view of an EngineResult (no transcript text).
public struct EngineResultDiagnostics: Sendable, Equatable {
    public let completeness: EngineResultCompleteness
    public let termination: EngineResultTermination
    public let engine: EngineIdentity
    public let languageRequested: String?
    public let languageDetected: String?
    public let confidence: Float?
    public let confidenceSource: String?
    public let inferenceDurationNanos: UInt64?
    public let warnings: [EngineWarning]
    public let fallbackReason: String?
    public let frameAccounting: EngineFrameAccounting?
}

/// Engine/model identity (version/digest when available).
public struct EngineIdentity: Sendable, Equatable {
    public let kind: EngineKind
    public let modelName: String
    public let modelVersion: String?
    public let modelDigest: String?

    public init(
        kind: EngineKind, modelName: String, modelVersion: String?,
        modelDigest: String?
    ) {
        self.kind = kind
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.modelDigest = modelDigest
    }
}

/// Backward-compat migration for `FinalTranscription` callers: the old
/// success-shaped container is replaced by `EngineResult`. This alias keeps
/// the migration explicit (compile error surfaces remain in callers).
public typealias FinalTranscription = EngineResult

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

    /// Folder name under WhisperKit / Hugging Face caches.
    public var whisperKitFolderName: String? {
        switch self {
        case .appleSpeech: return nil
        case .whisperTiny, .whisperBase, .whisperSmall: return rawValue
        }
    }
}

// MARK: - Model readiness

public enum ModelReadinessState: Sendable, Equatable {
    case notApplicable
    case missing
    case queued
    case downloading(Double?)  // 0...1 when known; nil = indeterminate
    case verifying
    case ready
    case cancelled
    case quarantined
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct ModelReadiness: Sendable, Equatable {
    public var state: ModelReadinessState
    public var bytesOnDisk: Int64?

    public init(state: ModelReadinessState, bytesOnDisk: Int64? = nil) {
        self.state = state
        self.bytesOnDisk = bytesOnDisk
    }

    public static let notApplicable = ModelReadiness(state: .notApplicable)
}

// MARK: - Flow backend

public enum FlowBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case regex
    /// On-device **rule-enhanced** cleanup (not an LLM). Kept raw value `neural` only for
    /// forward-compat with early settings; display name is honest.
    case enhanced = "neural"
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .regex: return "Classic (instant)"
        case .enhanced: return "Enhanced (on-device rules)"
        case .auto: return "Auto (enhanced when available)"
        }
    }

}

// MARK: - Insertion mode / strategy

public enum InsertionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case alwaysPaste
    case alwaysCopy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .alwaysPaste: return "Always paste"
        case .alwaysCopy: return "Always copy only"
        }
    }
}

public enum InsertionStrategy: String, Sendable, CaseIterable {
    case clipboardPaste
    case axSelectedText
    case axValue
    case terminalPaste
    case copyOnly
}

// MARK: - Hotkey

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var keyCode: UInt16?
    public var modifiers: UInt
    public var displayName: String
    public var specialKey: SpecialHotkey?
    /// JOE-2286: explicit experimental opt-in for the AppleFnUsageType
    /// override. The production default path NEVER touches the system
    /// preference; the override only begins after this opt-in AND
    /// successful hotkey/tap preparation.
    public var experimentalFnOverride: Bool

    public enum SpecialHotkey: String, Codable, Sendable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
    }

    public init(
        keyCode: UInt16?, modifiers: UInt, displayName: String, specialKey: SpecialHotkey?,
        experimentalFnOverride: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
        self.specialKey = specialKey
        self.experimentalFnOverride = experimentalFnOverride
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
        keyCode: 49,  // space
        modifiers: 1 << 18,  // NSEvent.ModifierFlags.control / CGEventFlags.maskControl
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
    public var language: SupportedLanguage
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
    /// Post-STT cleanup backend. Default regex keeps Clean path instant.
    public var flowBackend: FlowBackend
    /// How text is delivered to the target app.
    public var insertionMode: InsertionMode
    /// Persisted panel origin (screen coords); nil = auto near cursor.
    public var panelOriginX: Double?
    public var panelOriginY: Double?
    /// User dragged the panel; honor saved origin until reset.
    public var panelPositionLocked: Bool
    /// Local user override: exact bundle IDs that must be copy-only
    /// (JOE-2271). No remote configuration; never telemetry.
    /// Persisted completed onboarding capabilities (JOE-2282).
    public var completedCapabilities: [String]
    public var copyOnlyOverrideBundleIDs: [String]

    public init(
        hotkey: HotkeyConfig,
        preferredModel: ModelIdentifier,
        defaultFlowStyle: FlowStyle,
        language: SupportedLanguage,
        localOnlyMode: Bool,
        allowModelDownloads: Bool = false,
        launchAtLogin: Bool,
        listeningMode: ListeningMode,
        hasCompletedOnboarding: Bool,
        saveHistory: Bool = true,
        debugLogging: Bool = false,
        flowBackend: FlowBackend = .regex,
        insertionMode: InsertionMode = .automatic,
        completedCapabilities: [String] = [],
        panelOriginX: Double? = nil,
        panelOriginY: Double? = nil,
        panelPositionLocked: Bool = false,
        copyOnlyOverrideBundleIDs: [String] = []
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
        self.flowBackend = flowBackend
        self.insertionMode = insertionMode
        self.completedCapabilities = completedCapabilities
        self.panelOriginX = panelOriginX
        self.panelOriginY = panelOriginY
        self.panelPositionLocked = panelPositionLocked
        self.copyOnlyOverrideBundleIDs = copyOnlyOverrideBundleIDs
    }

    // JOE-2282: backward-compatible decode — new fields default; existing
    // payloads (any schema) remain decodable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hotkey = try c.decode(HotkeyConfig.self, forKey: .hotkey)
        self.preferredModel = try c.decode(ModelIdentifier.self, forKey: .preferredModel)
        self.defaultFlowStyle = try c.decode(FlowStyle.self, forKey: .defaultFlowStyle)
        self.language = try c.decode(SupportedLanguage.self, forKey: .language)
        self.localOnlyMode = try c.decode(Bool.self, forKey: .localOnlyMode)
        self.allowModelDownloads = try c.decodeIfPresent(Bool.self, forKey: .allowModelDownloads) ?? false
        self.launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
        self.listeningMode = try c.decode(ListeningMode.self, forKey: .listeningMode)
        self.hasCompletedOnboarding = try c.decode(Bool.self, forKey: .hasCompletedOnboarding)
        self.saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        self.debugLogging = try c.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        self.flowBackend = try c.decodeIfPresent(FlowBackend.self, forKey: .flowBackend) ?? .regex
        self.insertionMode = try c.decodeIfPresent(InsertionMode.self, forKey: .insertionMode) ?? .automatic
        self.completedCapabilities = try c.decodeIfPresent([String].self, forKey: .completedCapabilities) ?? []
        self.panelOriginX = try c.decodeIfPresent(Double.self, forKey: .panelOriginX)
        self.panelOriginY = try c.decodeIfPresent(Double.self, forKey: .panelOriginY)
        self.panelPositionLocked = try c.decodeIfPresent(Bool.self, forKey: .panelPositionLocked) ?? false
        self.copyOnlyOverrideBundleIDs = try c.decodeIfPresent([String].self, forKey: .copyOnlyOverrideBundleIDs) ?? []
    }

    public static let `default` = AppSettings(
        hotkey: .default,
        preferredModel: .whisperTiny,
        defaultFlowStyle: .clean,
        language: .auto,
        localOnlyMode: true,
        allowModelDownloads: true,
        launchAtLogin: false,
        listeningMode: .holdToTalk,
        hasCompletedOnboarding: false,
        saveHistory: false,
        debugLogging: false,
        flowBackend: .regex,
        insertionMode: .automatic,
        panelOriginX: nil,
        panelOriginY: nil,
        panelPositionLocked: false,
        copyOnlyOverrideBundleIDs: []
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

// MARK: - Insertion outcome (JOE-2269)

/// Content-free controlled evidence about what actually happened at the
/// target. Never contains field text or document titles.
public enum InsertionEvidence: String, Codable, CaseIterable, Sendable, Equatable {
    /// Post-write re-read of the selected-text/value range matched the
    /// inserted payload (in-memory compare only; never logged).
    case postWriteSelectionReRead
    /// Clipboard was restored to its prior content after a paste.
    case clipboardRestored
    /// The strategy provides no post-write confirmation.
    case none
}

/// Content-free warnings attached to an outcome.
public enum InsertionWarning: String, Codable, CaseIterable, Sendable, Equatable {
    case noPostWriteVerification
    case clipboardFallbackUsed
    case targetCapabilityUnknown
    case restoreDeferred
}

/// Typed, controlled outcome of an insertion path (JOE-2269). Replaces the
/// ambiguous legacy `InsertionResult` (`.pasted` / `.copiedToClipboard` were
/// treated as verified success). Every insertion path returns exactly one of
/// these; UI, history and metrics consume the outcome centrally through the
/// policy properties below (exhaustive switches => adding a case is a compile
/// error until policy is defined).
public enum InsertionOutcome: Sendable, Equatable {
    /// Confirmed at the target via post-write evidence.
    case verifiedInserted(strategy: InsertionStrategy, evidence: InsertionEvidence, warnings: [InsertionWarning])
    /// Event was posted (e.g. Cmd-V) but the target never confirmed receipt.
    case eventPostedUnverified(strategy: InsertionStrategy, warnings: [InsertionWarning])
    /// The user explicitly chose copy (review panel / copy-only adapter).
    case explicitlyCopiedByUser
    // --- no-side-effect uncertainty states (JOE-2268 mapping) ---
    case targetChanged
    case targetGone
    case targetUnknown
    case secureTarget
    case notEditable
    // --- clipboard hygiene failures ---
    case clipboardNotRestoredBecauseChanged
    case clipboardRestoreFailed
    // --- timing / lifecycle ---
    case deadlineExceeded
    case cancelled
    // --- typed failure (message is a user-safe reason, never transcript) ---
    case failed(String)

    public var strategy: InsertionStrategy? {
        switch self {
        case .verifiedInserted(let s, _, _), .eventPostedUnverified(let s, _):
            return s
        default:
            return nil
        }
    }

    /// True only when the target confirmed the write.
    public var isVerifiedSuccess: Bool {
        if case .verifiedInserted = self { return true }
        return false
    }

    /// Non-success, non-uncertain outcomes that still completed a user-visible
    /// action (copy / unverified post).
    public var isCompletedAction: Bool {
        switch self {
        case .verifiedInserted, .explicitlyCopiedByUser, .eventPostedUnverified:
            return true
        default:
            return false
        }
    }

    /// Outcomes that must never show green success UI.
    public var permitsGreenSuccessUI: Bool {
        switch self {
        case .verifiedInserted, .explicitlyCopiedByUser: return true
        case .eventPostedUnverified: return false
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .cancelled, .failed:
            return false
        }
    }

    /// History retention policy (central, JOE-2269).
    public var permitsHistoryRetention: Bool {
        switch self {
        case .verifiedInserted, .explicitlyCopiedByUser: return true
        case .eventPostedUnverified: return false
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .cancelled, .failed:
            return false
        }
    }

    /// Automatic panel dismissal policy.
    public var permitsAutomaticPanelDismissal: Bool {
        switch self {
        case .verifiedInserted: return true
        case .explicitlyCopiedByUser: return true
        case .eventPostedUnverified: return true
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .cancelled, .failed:
            return false
        }
    }

    /// Reliability metrics policy (content-free counters only).
    public var permitsReliabilityMetrics: Bool {
        switch self {
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .cancelled, .failed:
            return true
        }
    }

    /// Uncertain states that require the review UX (JOE-2272), never
    /// auto-paste/copy/dismiss-as-success.
    public var isUncertain: Bool {
        switch self {
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .deadlineExceeded:
            return true
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
            .cancelled, .failed:
            return false
        }
    }

    /// User-visible language distinguishing verified / unverified / copy /
    /// no-side-effect. Never technical AX terminology, never content.
    public var userFacingMessage: String {
        switch self {
        case .verifiedInserted: return "Inserted"
        case .eventPostedUnverified: return "Inserted — unverified"
        case .explicitlyCopiedByUser: return "Copied to clipboard"
        case .targetChanged: return "Target changed — nothing was inserted"
        case .targetGone: return "Target closed — nothing was inserted"
        case .targetUnknown: return "Target unknown — nothing was inserted"
        case .secureTarget: return "Secure field — review before copying"
        case .notEditable: return "Field is not editable — nothing was inserted"
        case .clipboardNotRestoredBecauseChanged:
            return "Clipboard was left as-is because it changed"
        case .clipboardRestoreFailed: return "Could not restore clipboard"
        case .deadlineExceeded: return "Target validation timed out"
        case .cancelled: return "Cancelled"
        case .failed(let msg): return msg
        }
    }
}

// MARK: - Panel State

public enum PanelState: Equatable, Sendable {
    case hidden
    case listening
    case processing
    case reviewing
    case success
    case warning
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
