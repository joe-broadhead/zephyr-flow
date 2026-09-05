import Foundation

// MARK: - Transcription

public struct PartialTranscription: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let timestamp: Date
    /// Producer-reported terminal capture event, not proof of complete audio
    /// or native resource quiescence. The session must stop and assess/review.
    public let captureEnded: Bool

    public init(text: String, isFinal: Bool = false, timestamp: Date = Date(), captureEnded: Bool = false) {
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.captureEnded = captureEnded
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
        guard capturedSourceSamples > 0, deliveredEngineSamples > 0,
            droppedSourceSamples <= capturedSourceSamples,
            converterRatio.isFinite, converterRatio > 0
        else { return false }
        guard deliveredEngineSamples == decodedEngineSamples else { return false }
        // Counts beyond exact Double integer precision cannot support a
        // rounding-tolerance proof. They are far above admitted session limits.
        let exactIntegerLimit: UInt64 = (1 << 53) - 1
        guard capturedSourceSamples <= exactIntegerLimit, deliveredEngineSamples <= exactIntegerLimit,
            roundingToleranceSamples <= exactIntegerLimit
        else { return false }
        let expected = Double(capturedSourceSamples - droppedSourceSamples) * converterRatio
        guard expected.isFinite, expected >= 0, expected <= Double(exactIntegerLimit) else { return false }
        // Compare without truncating fractional differences or converting
        // NaN/infinity/out-of-range Double into UInt64 (which would trap).
        return abs(expected - Double(deliveredEngineSamples)) <= Double(roundingToleranceSamples)
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
        guard completeness == .complete, termination == .completed,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let accounting = frameAccounting, accounting.droppedSourceSamples == 0
        else { return false }
        guard
            !warnings.contains(where: { warning in
                switch warning {
                case .partialFallback, .shortAudioFallback, .deadlineExceeded, .truncation, .captureDegraded:
                    return true
                case .lowConfidence, .engineFallback: return false
                }
            })
        else { return false }
        return accounting.reconciled(converterRatio: 1.0, roundingToleranceSamples: 64)
    }

    /// Session admission cannot trust a success-shaped enum alone. Preserve
    /// text and raw evidence for review, never invent counts or a final event.
    public func requiringCompletionEvidence(captureEndedEarly: Bool = false) -> EngineResult {
        guard completeness == .complete, captureEndedEarly || !isComplete else { return self }
        return EngineResult(
            text: text, completeness: .partial, frameAccounting: frameAccounting,
            engine: engine, languageRequested: languageRequested, languageDetected: languageDetected,
            confidence: confidence, confidenceSource: confidenceSource,
            startedAtUptimeNanos: startedAtUptimeNanos, endedAtUptimeNanos: endedAtUptimeNanos,
            inferenceDurationNanos: inferenceDurationNanos,
            warnings: warnings.contains(.captureDegraded) ? warnings : warnings + [.captureDegraded],
            fallbackReason: captureEndedEarly
                ? "engine capture ended before release; review required"
                : "completion evidence missing or inconsistent; review required", termination: termination)
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

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, displayName, specialKey, experimentalFnOverride
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifiers = try values.decode(UInt.self, forKey: .modifiers)
        displayName = try values.decode(String.self, forKey: .displayName)
        specialKey = try values.decodeIfPresent(SpecialHotkey.self, forKey: .specialKey)
        // Older saved shortcuts predate the override toggle. Preserve their
        // binding, never infer consent or replace them with the new default.
        experimentalFnOverride = try values.decodeIfPresent(Bool.self, forKey: .experimentalFnOverride) ?? false
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

    /// Human-selected new-install default (JOE-2285). Saved configurations are
    /// decoded unchanged; selecting this combo never enables the Fn override.
    public static let `default` = controlOptionSpace

    public static let controlOptionSpace = HotkeyConfig(
        keyCode: 49,
        modifiers: (1 << 18) | (1 << 19),
        displayName: "Control + Option + Space",
        specialKey: nil)

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
    /// Allows one-time Whisper model file downloads (does not upload audio). Default OFF until explicit onboarding consent (review R6.1); enabling it makes Whisper Tiny work.
    public var allowModelDownloads: Bool
    public var launchAtLogin: Bool
    public var listeningMode: ListeningMode
    public var hasCompletedOnboarding: Bool
    /// When false, dictations are not written to the history repository.
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
        saveHistory: Bool = false,
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
        // Review REQ-5: a missing saveHistory decodes to FALSE (privacy-safe,
        // matching the new-install default) — a migrated/partial payload must
        // never unexpectedly enable history.
        self.saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? false
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
        // Review R6.1: downloads default DISABLED until explicit onboarding
        // consent. (The init default is false; this static default was the
        // outlier enabling pre-consent acquisition.)
        allowModelDownloads: false,
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
    /// The user explicitly chose copy from the review panel.
    case explicitlyCopiedByUser
    /// Clipboard was written automatically (copy-only mode or fallback), NOT
    /// by an explicit review-panel action. Non-success: user must confirm.
    case automaticCopy
    /// A policy-blocked automatic clipboard write was refused: the clipboard
    /// was NOT written.
    case automaticCopyBlocked
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
    /// A timed-out side-effecting AX write MAY have applied: the operation was
    /// dispatched and the deadline elapsed before it was known not to have
    /// taken effect. Never claim "nothing was inserted"; automatic retry is
    /// disabled (a retry could duplicate or target a stale element).
    case writeMayHaveApplied
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
        case .verifiedInserted, .explicitlyCopiedByUser, .eventPostedUnverified,
            .automaticCopy:
            return true
        default:
            return false
        }
    }

    /// Outcomes that must never show green success UI.
    public var permitsGreenSuccessUI: Bool {
        switch self {
        case .verifiedInserted, .explicitlyCopiedByUser: return true
        case .eventPostedUnverified, .automaticCopy, .automaticCopyBlocked: return false
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .writeMayHaveApplied,
            .cancelled, .failed:
            return false
        }
    }

    /// History retention policy (central, JOE-2269).
    public var permitsHistoryRetention: Bool {
        switch self {
        case .verifiedInserted, .explicitlyCopiedByUser: return true
        case .eventPostedUnverified, .automaticCopy, .automaticCopyBlocked: return false
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .writeMayHaveApplied,
            .cancelled, .failed:
            return false
        }
    }

    /// Automatic panel dismissal policy.
    public var permitsAutomaticPanelDismissal: Bool {
        switch self {
        case .verifiedInserted: return true
        case .explicitlyCopiedByUser: return true
        case .eventPostedUnverified: return true
        case .automaticCopy, .automaticCopyBlocked: return false
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .writeMayHaveApplied,
            .cancelled, .failed:
            return false
        }
    }

    /// Reliability metrics policy (content-free counters only).
    public var permitsReliabilityMetrics: Bool {
        switch self {
        case .verifiedInserted, .eventPostedUnverified, .explicitlyCopiedByUser,
            .automaticCopy, .automaticCopyBlocked,
            .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .clipboardNotRestoredBecauseChanged,
            .clipboardRestoreFailed, .deadlineExceeded, .writeMayHaveApplied,
            .cancelled, .failed:
            return true
        }
    }

    /// Uncertain states that require the review UX (JOE-2272), never
    /// auto-paste/copy/dismiss-as-success.
    public var isUncertain: Bool {
        switch self {
        case .targetChanged, .targetGone, .targetUnknown, .secureTarget,
            .notEditable, .deadlineExceeded, .writeMayHaveApplied,
            .automaticCopy, .automaticCopyBlocked:
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
        case .eventPostedUnverified: return "Paste sent — verify destination"
        case .explicitlyCopiedByUser: return "Copied to clipboard"
        case .automaticCopy: return "Copied to clipboard (automatic) — verify the destination"
        case .automaticCopyBlocked: return "Automatic clipboard blocked — review before copying"
        case .targetChanged: return "Target changed — nothing was inserted"
        case .targetGone: return "Target closed — nothing was inserted"
        case .targetUnknown: return "Target unknown — nothing was inserted"
        case .secureTarget: return "Secure field — review before copying"
        case .notEditable: return "Field is not editable — nothing was inserted"
        case .clipboardNotRestoredBecauseChanged:
            return "Clipboard was left as-is because it changed"
        case .clipboardRestoreFailed: return "Could not restore clipboard"
        case .deadlineExceeded: return "Target validation timed out"
        case .writeMayHaveApplied: return "The write may have applied — verify the destination before retrying"
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
