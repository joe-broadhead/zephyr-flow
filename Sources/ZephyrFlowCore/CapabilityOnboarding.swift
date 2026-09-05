import Foundation

// JOE-2282: capability-based onboarding — steps are derived from a
// capability graph, not one fixed enum sequence. The product asks only for
// capabilities the selected path needs, explains every permission/network
// action honestly, persists completed capabilities (not a boolean), and
// requests only the missing delta when settings change.

// MARK: - Capabilities

public enum OnboardingCapability: String, Codable, CaseIterable, Sendable, Equatable {
    case microphone
    case speechRecognition
    case accessibility
    case modelAcquisition
    case networkModelDownload
    case networkUpdateCheck
    case clipboardDisclosure
    case systemDictation
    case languageAvailability
    case localOnlyImplications
}

/// Current capabilities, not historical consent or a persisted "done" flag.
/// The UI's engineLoaded value comes only from current loaded/preflighted
/// preparation. Permission checks here never trigger system prompts.
public struct OnboardingReadinessSnapshot: Sendable {
    public let microphone: Bool
    public let speech: Bool
    public let accessibility: Bool
    public let downloadConsent: Bool
    public let engineLoaded: Bool

    public init(microphone: Bool, speech: Bool, accessibility: Bool, downloadConsent: Bool, engineLoaded: Bool) {
        self.microphone = microphone
        self.speech = speech
        self.accessibility = accessibility
        self.downloadConsent = downloadConsent
        self.engineLoaded = engineLoaded
    }

    public func satisfies(_ capability: OnboardingCapability) -> Bool {
        switch capability {
        case .microphone: return microphone
        case .speechRecognition: return speech
        case .accessibility: return accessibility
        case .networkModelDownload: return downloadConsent
        case .modelAcquisition, .languageAvailability: return engineLoaded
        default: return true  // disclosure acknowledgment is tracked separately
        }
    }
}

// MARK: - Steps

public struct OnboardingStep: Sendable, Equatable {
    public let id: String
    public let capability: OnboardingCapability
    public let title: String
    public let explanation: String
    // JOE-2289: localization-ready semantic keys (English values above are
    // the fallback/display; a locale pipeline resolves via AppStrings).
    public let titleKey: String
    public let explanationKey: String
    /// A system permission prompt (TCC/AX) requiring explicit user action.
    public let requiresSystemPrompt: Bool
    /// Network class: none / modelDownload / updateCheck — shown separately
    /// from audio privacy.
    public let networkClass: String
    /// Whether the user may skip this step (recoverable limited mode).
    public let skippable: Bool

    public init(
        id: String, capability: OnboardingCapability,
        title: String, explanation: String,
        titleKey: String? = nil, explanationKey: String? = nil,
        requiresSystemPrompt: Bool, networkClass: String = "none",
        skippable: Bool = true
    ) {
        self.id = id
        self.capability = capability
        self.title = title
        self.explanation = explanation
        self.titleKey = titleKey ?? "onboarding.\(id).title"
        self.explanationKey = explanationKey ?? "onboarding.\(id).explanation"
        self.requiresSystemPrompt = requiresSystemPrompt
        self.networkClass = networkClass
        self.skippable = skippable
    }
}

// MARK: - Product paths

public enum OnboardingProductPath: String, CaseIterable, Sendable, Equatable {
    /// WhisperKit on-device with automatic insertion (needs AX).
    case whisperKitAutomatic
    /// WhisperKit on-device, clipboard/review only (no AX).
    case whisperKitClipboardOnly
    /// Apple Speech with automatic insertion.
    case appleSpeechAutomatic
    /// Apple Speech, clipboard/review only.
    case appleSpeechClipboardOnly
}

// MARK: - Capability graph (deterministic)

public enum CapabilityGraph: Sendable {
    /// Deterministic step sequence for a product path. Rules:
    ///  - WhisperKit paths NEVER request Speech Recognition or System
    ///    Dictation.
    ///  - Clipboard-only paths never imply Accessibility is required.
    ///  - Network actions (model download / update check) are listed
    ///    separately from audio privacy.
    public static func steps(for path: OnboardingProductPath) -> [OnboardingStep] {
        switch path {
        case .whisperKitAutomatic:
            return [
                OnboardingStep(
                    id: "mic", capability: .microphone,
                    title: "Microphone",
                    explanation:
                        "Zephyr Flow needs the microphone to capture your speech. Audio is processed on-device and never uploaded.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "model", capability: .modelAcquisition,
                    title: "Speech model",
                    explanation:
                        "Whisper runs fully on your Mac. The model files are downloaded once from Hugging Face (no audio ever leaves your machine).",
                    requiresSystemPrompt: false,
                    networkClass: "modelDownload"),
                OnboardingStep(
                    id: "ax", capability: .accessibility,
                    title: "Accessibility (optional)",
                    explanation:
                        "Automatic insertion at your cursor uses Accessibility. You can skip this and use Copy instead.",
                    requiresSystemPrompt: true,
                    skippable: true),
                OnboardingStep(
                    id: "ready", capability: .localOnlyImplications,
                    title: "You're set",
                    explanation: "Hold Fn, speak, release — text appears at your cursor. Local Only is on by default.",
                    requiresSystemPrompt: false),
            ]
        case .whisperKitClipboardOnly:
            return [
                OnboardingStep(
                    id: "mic", capability: .microphone,
                    title: "Microphone",
                    explanation:
                        "Zephyr Flow needs the microphone to capture your speech. Audio is processed on-device and never uploaded.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "model", capability: .modelAcquisition,
                    title: "Speech model",
                    explanation:
                        "Whisper runs fully on your Mac. The model files are downloaded once from Hugging Face (no audio ever leaves your machine).",
                    requiresSystemPrompt: false,
                    networkClass: "modelDownload"),
                OnboardingStep(
                    id: "clipboard", capability: .clipboardDisclosure,
                    title: "Clipboard mode",
                    explanation:
                        "You chose Copy/Review mode: dictations are copied to the clipboard for you to paste. Nothing is inserted automatically and Accessibility is NOT required.",
                    requiresSystemPrompt: false),
                OnboardingStep(
                    id: "ready", capability: .localOnlyImplications,
                    title: "You're set",
                    explanation:
                        "Hold Fn, speak, release — text is copied for you to paste. Local Only is on by default.",
                    requiresSystemPrompt: false),
            ]
        case .appleSpeechAutomatic:
            return [
                OnboardingStep(
                    id: "mic", capability: .microphone,
                    title: "Microphone",
                    explanation: "Zephyr Flow needs the microphone to capture your speech.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "speech", capability: .speechRecognition,
                    title: "Speech Recognition",
                    explanation:
                        "Apple Speech uses the on-device recognizer. With Local Only on, audio never leaves your Mac.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "lang", capability: .languageAvailability,
                    title: "Language pack",
                    explanation:
                        "Apple Speech needs the requested locale available on-device. A missing pack limits recognition and is explained here.",
                    requiresSystemPrompt: false),
                OnboardingStep(
                    id: "ax", capability: .accessibility,
                    title: "Accessibility (optional)",
                    explanation:
                        "Automatic insertion at your cursor uses Accessibility. You can skip this and use Copy instead.",
                    requiresSystemPrompt: true,
                    skippable: true),
                OnboardingStep(
                    id: "ready", capability: .localOnlyImplications,
                    title: "You're set",
                    explanation: "Hold Fn, speak, release — text appears at your cursor.",
                    requiresSystemPrompt: false),
            ]
        case .appleSpeechClipboardOnly:
            return [
                OnboardingStep(
                    id: "mic", capability: .microphone,
                    title: "Microphone",
                    explanation: "Zephyr Flow needs the microphone to capture your speech.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "speech", capability: .speechRecognition,
                    title: "Speech Recognition",
                    explanation:
                        "Apple Speech uses the on-device recognizer. With Local Only on, audio never leaves your Mac.",
                    requiresSystemPrompt: true),
                OnboardingStep(
                    id: "lang", capability: .languageAvailability,
                    title: "Language pack",
                    explanation: "Check the selected Apple Speech language and on-device availability before capture.",
                    requiresSystemPrompt: false),
                OnboardingStep(
                    id: "clipboard", capability: .clipboardDisclosure,
                    title: "Clipboard mode",
                    explanation:
                        "You chose Copy/Review mode: dictations are copied to the clipboard for you to paste. Accessibility is NOT required.",
                    requiresSystemPrompt: false),
                OnboardingStep(
                    id: "ready", capability: .localOnlyImplications,
                    title: "You're set",
                    explanation: "Hold Fn, speak, release — text is copied for you to paste.",
                    requiresSystemPrompt: false),
            ]
        }
    }

    /// Deterministic delta: steps whose capability is not yet completed.
    public static func remainingSteps(
        for path: OnboardingProductPath,
        completed: Set<OnboardingCapability>
    ) -> [OnboardingStep] {
        steps(for: path).filter { !completed.contains($0.capability) }
    }

    public static func isComplete(
        for path: OnboardingProductPath,
        completed: Set<OnboardingCapability>
    ) -> Bool {
        remainingSteps(for: path, completed: completed).isEmpty
    }

    /// Human explanation of a skip (limitations + recoverable).
    public static func skipExplanation(
        for path: OnboardingProductPath,
        step: OnboardingStep
    ) -> (limitations: String, recoverable: Bool) {
        switch step.capability {
        case .microphone, .speechRecognition:
            return (
                "Without \(step.title), dictation cannot capture or recognize speech. You can grant it later in System Settings and resume setup.",
                true
            )
        case .accessibility:
            return (
                "Without Accessibility, text is not inserted automatically at the cursor. You can use Copy/Review mode, or grant it later and resume setup.",
                true
            )
        case .modelAcquisition, .networkModelDownload:
            return (
                "Without the model, WhisperKit cannot transcribe. You can enable Model Downloads later and retry.",
                true
            )
        case .clipboardDisclosure:
            return (
                "Clipboard mode is required for copy-only workflow. You can switch back to automatic insertion in Settings.",
                true
            )
        case .languageAvailability, .localOnlyImplications, .networkUpdateCheck, .systemDictation:
            return (
                "This step is informational; continue to finish setup.",
                true
            )
        }
    }

    /// Derive the product path from persisted settings (deterministic).
    public static func path(
        model: ModelIdentifier,
        insertionMode: String
    ) -> OnboardingProductPath {
        let clipboardOnly = insertionMode == "alwaysCopy"
        switch model {
        case .appleSpeech:
            return clipboardOnly ? .appleSpeechClipboardOnly : .appleSpeechAutomatic
        default:
            return clipboardOnly ? .whisperKitClipboardOnly : .whisperKitAutomatic
        }
    }
}
