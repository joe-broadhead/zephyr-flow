import Foundation

// JOE-2289: localization-ready string catalog. Stable semantic keys with
// translator context; UI locale is INDEPENDENT of the selected transcription
// language. Fallback: missing translation -> English; unsupported locale ->
// English. Technical identifiers (model IDs, bundle IDs, paths) are never
// localized. Formatted numbers/bytes/durations use locale-aware APIs.

public enum AppStrings {
    // MARK: - Catalog (key -> English + translator context)

    /// Semantic keys with translator context. Values are the English (source)
    /// strings; a future Localizable pipeline maps key+locale -> translation.
    public static let catalog: [String: (value: String, context: String)] = [
        // Onboarding (graph steps)
        "onboarding.welcome.title": ("Private dictation,\non your machine", "Onboarding welcome heading"),
        "onboarding.welcome.explanation": (
            "Hold Fn, speak, release — text appears at your cursor. Local Only is on by default. Steps below ask only for what the selected product path needs.",
            "Onboarding welcome explanation"
        ),
        "onboarding.mic.title": ("Microphone", "Onboarding microphone step heading"),
        "onboarding.mic.explanation": (
            "Zephyr Flow needs the microphone to capture your speech. Audio is processed on-device and never uploaded.",
            "Onboarding microphone explanation"
        ),
        "onboarding.model.title": ("Speech model", "Onboarding model step heading"),
        "onboarding.model.explanation": (
            "Whisper runs fully on your Mac. The model files are downloaded once from Hugging Face (no audio ever leaves your machine).",
            "Onboarding model download disclosure"
        ),
        "onboarding.ax.title": ("Accessibility (optional)", "Onboarding accessibility step heading"),
        "onboarding.ax.explanation": (
            "Automatic insertion at your cursor uses Accessibility. You can skip this and use Copy instead.",
            "Onboarding accessibility explanation"
        ),
        "onboarding.clipboard.title": ("Clipboard mode", "Onboarding clipboard-mode step heading"),
        "onboarding.clipboard.explanation": (
            "You chose Copy/Review mode: dictations are copied to the clipboard for you to paste. Nothing is inserted automatically and Accessibility is NOT required.",
            "Onboarding clipboard disclosure"
        ),
        "onboarding.speech.title": ("Speech Recognition", "Onboarding speech recognition step heading"),
        "onboarding.speech.explanation": (
            "Apple Speech uses the on-device recognizer. With Local Only on, audio never leaves your Mac.",
            "Onboarding speech recognition explanation"
        ),
        "onboarding.lang.title": ("Language pack", "Onboarding language availability step heading"),
        "onboarding.lang.explanation": (
            "Apple Speech needs the requested locale available on-device. A missing pack limits recognition and is explained here.",
            "Onboarding language availability explanation"
        ),
        "onboarding.ready.title": ("You're set", "Onboarding completion heading"),
        "onboarding.ready.explanation": (
            "Hold Fn, speak, release — text appears at your cursor. Local Only is on by default.",
            "Onboarding completion explanation"
        ),
        "onboarding.ready.copy.explanation": (
            "Hold Fn, speak, release — text is copied for you to paste. Local Only is on by default.",
            "Onboarding completion explanation (clipboard mode)"
        ),
        "onboarding.ready.apple.explanation": (
            "Hold Fn, speak, release — text appears at your cursor.", "Onboarding completion explanation (Apple Speech)"
        ),
        "onboarding.ready.apple.copy.explanation": (
            "Hold Fn, speak, release — text is copied for you to paste.",
            "Onboarding completion explanation (Apple Speech clipboard)"
        ),
        "onboarding.back": ("Back", "Onboarding back button"),
        "onboarding.getStarted": ("Get started", "Onboarding start button"),
        "onboarding.startUsing": ("Start using ZephyrFlow", "Onboarding finish button"),
        "onboarding.skip": ("Skip", "Onboarding skip button"),
        "onboarding.allowMic": ("Allow Microphone", "Onboarding primary action"),
        "onboarding.allowSpeech": ("Allow Speech Recognition", "Onboarding primary action"),
        "onboarding.enableAX": ("Enable Accessibility", "Onboarding primary action"),
        "onboarding.downloadModel": ("Download Model", "Onboarding primary action"),
        "onboarding.continue": ("Continue", "Onboarding default primary action"),
        "onboarding.granted": ("Granted", "Onboarding status chip"),
        "onboarding.notGranted": ("Not granted yet", "Onboarding status chip"),
        "onboarding.checklanguage": ("Check selected language", "Explicit no-capture capability/load check"),
        "onboarding.preparelocal": ("Load verified local model", "Cache hit does not grant download consent"),
        "onboarding.limited.title": ("Setup is incomplete", "A skipped/failed capability must not appear ready"),
        "onboarding.limited.continue": (
            "Continue in limited mode", "Close setup without claiming capabilities are complete"
        ),
        "onboarding.limited.explanation": (
            "Missing permissions or an unloaded engine still limit dictation. You can go back now, or reopen Setup later. No microphone starts before the selected engine is prepared.",
            "Truthful limited-mode completion page"
        ),
        // Settings
        "settings.history": ("History", "Settings history section"),
        "settings.clearAll": ("Clear All", "Settings history clear button"),
        "settings.emptyHistory": ("Your recent dictations will appear here.", "Settings empty history state"),
        "settings.copy": ("Copy", "History entry copy action"),
        "settings.delete": ("Delete", "History entry delete action"),
        "settings.aboutTitle": ("ZephyrFlow", "Settings about app name"),
        "settings.aboutSubtitle": ("Private voice-to-text that appears at your cursor", "Settings about subtitle"),
        "settings.checking": ("Checking…", "Update check in progress"),
        "settings.checkForUpdates": ("Check for Updates", "Update check button"),
        "settings.download": ("Download", "Update download button"),
        "settings.releaseNotes": ("Release Notes", "Update release notes button"),
        "settings.updatePrivacyNote": (
            "Checks GitHub Releases only when you click the button. No background update ping.",
            "Update check privacy explanation"
        ),
        "settings.openSettings": ("Open Settings", "Menu bar settings action"),
        "settings.hotkey.fn": ("Fn", "Hotkey choice label"),
        "settings.hotkey.rightOption": ("Right Option (⌥)", "Hotkey choice label"),
        "settings.hotkey.rightCommand": ("Right Command (⌘)", "Hotkey choice label"),
        "settings.hotkey.controlSpace": ("Control + Space", "Hotkey choice label"),
        "settings.hotkey.optionSpace": ("Option + Space", "Hotkey choice label"),
        "settings.axNote": (
            "Requires Accessibility permission. After enabling it, quit and reopen ZephyrFlow.",
            "Accessibility permission note"
        ),
        "settings.modelDownloadsOff": (
            "Model downloads are off — Whisper needs a cached model, or pick Apple Speech.", "Model downloads warning"
        ),
        "settings.refreshModelStatus": ("Refresh model status", "Model status refresh button"),
        "engine.preparation.title": ("Engine preparation", "Selected speech engine preparation section"),
        "engine.preparation.diskspace": (
            "Model preparation needs at least 1.5 GB of free space under the current policy. Free space in your home volume, then retry.",
            "Existing ModelUIPolicy minimum headroom check; not a measured final model size"
        ),
        "engine.capability.speechpermission": (
            "Apple Speech needs Speech Recognition permission. Open Setup to grant it, then retry.",
            "Preparation cannot prompt; user must explicitly authorize Speech Recognition"
        ),
        "engine.capability.microphonepermission": (
            "Microphone permission is missing. Open Setup to grant it, then retry.", "Microphone preflight failure"
        ),
        "engine.capability.language": (
            "Apple Speech does not support the selected language on this Mac. Choose another language or Whisper.",
            "No silent language fallback"
        ),
        "engine.capability.ondevice": (
            "Local Only: the selected Apple Speech language is not available on device. Check language packs in System Settings or choose Whisper.",
            "Never fall back to network when on-device support is missing"
        ),
        "engine.capability.unavailable": (
            "Apple Speech is unavailable. Check Dictation in System Settings, then retry or choose Whisper.",
            "Recognizer availability preflight; does not claim a specific OS failure cause"
        ),
        "engine.preparation.progress": ("Preparing selected engine…", "Indeterminate preparation indicator"),
        "engine.preparation.cancel": (
            "Cancel preparation", "Stop waiting for preparation; native work may still finish"
        ),
        "engine.preparation.retry": ("Retry preparation", "Explicitly retry failed or cancelled engine preparation"),
        "engine.preparation.apple": ("Use Apple Speech", "Explicitly select Apple Speech; does not grant permissions"),
        "engine.preparation.waiting": (
            "Waiting for the previous model operation to finish…", "Retained native initializer has not completed"
        ),
        "engine.preparation.verifying": (
            "Verifying model files…", "Integrity checks before loading a selected artifact"
        ),
        "engine.preparation.acquiring": ("Acquiring model files…", "Model acquisition with no fabricated percentage"),
        "engine.preparation.loading": ("Loading speech engine…", "Artifact availability alone is not loaded readiness"),
        "engine.preparation.ready": (
            "Speech engine loaded", "Current engine candidate is loaded; not a device qualification claim"
        ),
        "engine.preparation.consent": (
            "Model files are missing. Enable Model Downloads or choose Apple Speech.", "No download without consent"
        ),
        "engine.preparation.cancelled": (
            "Preparation cancelled. Native work may still be finishing.",
            "UI cancellation does not imply native completion"
        ),
        "engine.preparation.failed": (
            "Could not prepare the speech engine. Retry or choose another engine.",
            "Controlled error without framework payloads"
        ),
        "engine.preparation.deferred": (
            "The selected model will load after this session finishes.", "Active session retains its original engine"
        ),
        "engine.preparation.notloaded": ("The selected speech engine is not loaded.", "Preparation admission refused"),
        "engine.files.verified": ("Verified files", "Artifact integrity status, not engine readiness"),
        "engine.files.verified.size": (
            "Verified files · %@", "Verified artifact status; parameter is localized byte count"
        ),
        "engine.downloads.disclosure": (
            "Model downloads are off until enabled. Downloads fetch model files from Hugging Face, never upload audio. Verified files are stored in ~/Library/Application Support/ZephyrFlow/VerifiedModels; the transport may also retain a Hugging Face cache.",
            "Model network purpose and actual storage locations; separate from Local Only audio policy"
        ),
        "settings.refreshStatus": ("Refresh status", "Permission status refresh button"),
        "settings.clearHistory": ("Clear local history", "History clear button"),
        "settings.debugNote": (
            "Writes extra hotkey/engine detail to ~/Library/Logs/ZephyrFlow/ (local only, rotated).",
            "Debug logging explanation"
        ),
        "settings.resetFnPreference": ("Reset system Fn / Globe key preference", "Hotkey reset button"),
        "settings.insertionAutoNote": (
            "Automatic picks paste vs Accessibility per app. Copy only never types keystrokes.",
            "Insertion mode explanation"
        ),
        "settings.resetPanelPosition": ("Reset panel position", "Panel position reset button"),
        // Panel / review
        "panel.openMicSettings": ("Open Microphone settings from the menu bar → Setup", "Panel microphone warning"),
        "panel.openAXSettings": (
            "Open Accessibility settings from the menu bar → Setup", "Panel accessibility warning"
        ),
        "panel.processing": ("Processing…", "Panel processing label"),
        "panel.reviewTitle": ("Review: %@", "Panel review title (parameter = review reason)"),
        "panel.retry": ("Retry", "Review retry button"),
        "panel.retryHint": ("Retry validation against the original target", "Review retry accessibility hint"),
        "panel.settings": ("Settings", "Review settings button"),
        "panel.openAX": ("Open Accessibility settings", "Review accessibility button"),
        "panel.discard": ("Discard", "Review discard button"),
        "panel.discardHint": ("Discard and clear the text", "Review discard accessibility hint"),
        "panel.autoClear": ("Clears automatically in 30s", "Review auto-clear note"),
        "panel.stopAndInsert": ("Stop and insert", "Panel stop button"),
        "panel.cancel": ("Cancel", "Panel cancel button"),
        "panel.dismiss": ("Dismiss", "Panel dismiss button"),
        "panel.dismissWarning": ("Dismiss warning", "Panel warning dismiss"),
        // Menu bar
        "menu.setup": ("Setup / Permissions…", "Menu bar setup action"),
        "menu.settings": ("Settings…", "Menu bar settings action"),
        "menu.checkUpdates": ("Check for Updates…", "Menu bar update action"),
        "menu.engine": ("Engine: %@", "Menu bar engine label (parameter = engine name)"),
        "menu.hotkey": ("Hotkey: %@", "Menu bar hotkey label (parameter = hotkey name)"),
        "menu.privacyLocalOnly": ("Privacy: Local Only", "Menu bar privacy indicator"),
        "menu.quit": ("Quit ZephyrFlow", "Menu bar quit action"),
        "menu.enableAX": ("Enable Accessibility…", "Menu bar accessibility action"),
        "menu.finishSetup": ("Finish Setup…", "Menu bar onboarding action"),
        "menu.hotkeyWarming": ("Hotkey warming up…", "Menu bar hotkey status"),
        "menu.fnReady": ("Fn ready", "Menu bar hotkey ready status"),
        "settings.section.general": ("General", "Settings section title"),
        "settings.section.history": ("History", "Settings section title"),
        "settings.section.hotkey": ("Hotkey", "Settings section title"),
        "settings.section.model": ("Model", "Settings section title"),
        "settings.section.flow": ("Flow", "Settings section title"),
        "settings.section.privacy": ("Privacy", "Settings section title"),
        "settings.section.about": ("About", "Settings section title"),
        "settings.picker.listeningMode": ("Listening mode", "Settings picker label"),
        "settings.picker.flowStyle": ("Default flow style", "Settings picker label"),
        "settings.picker.style": ("Style", "Settings picker label"),
        "settings.picker.hotkey": ("Hotkey", "Settings picker label"),
        "settings.picker.language": (
            "Language", "Settings picker label (transcription language — independent of UI locale)"
        ),
        "settings.picker.mode": ("Mode", "Settings picker label (insertion mode)"),
        "settings.picker.flowBackend": ("Flow backend", "Settings picker label"),
        "settings.toggle.localOnly": ("Local Only mode", "Settings toggle"),
        "settings.toggle.allowDownloads": ("Allow Whisper model downloads", "Settings toggle"),
        "settings.toggle.launchAtLogin": ("Launch at login", "Settings toggle"),
        "settings.toggle.saveHistory": ("Save transcription history", "Settings toggle"),
        "history.preparation.failed": (
            "Encrypted history is unavailable. Check history storage and Keychain access, then retry, or turn off saving history.",
            "Controlled initialization failure; never interpolate file paths or framework error payloads"
        ),
        "history.delete.failed": (
            "Could not delete the history entry. Retry after checking storage access.",
            "Controlled durable delete failure"
        ),
        "history.clear.failed": (
            "Could not clear history. Retry after checking storage access.", "Controlled durable clear failure"
        ),
        "history.write.failed": (
            "A history entry could not be saved. Check storage access before retrying.",
            "No arbitrary storage error payload in UI"
        ),
        "settings.toggle.debug": ("Debug logging", "Settings toggle"),
        "panel.help.stopInsert": ("Stop & Insert", "Panel button help"),
        "panel.help.cancelDiscard": ("Cancel (discard)", "Panel button help"),
    ]

    // MARK: - Resolution

    /// Resolve a key with English fallback; missing keys resolve to the key
    /// itself (surfaced by the completeness scan).
    public static func key(_ key: String) -> String {
        catalog[key]?.value ?? key
    }

    /// Format a parameterized string with locale-aware substitution.
    public static func format(_ catalogKey: String, _ args: CVarArg...) -> String {
        let template = key(catalogKey)
        let localized = template as NSString
        return localized.replacingOccurrences(of: "%@", with: args.first.map { String(describing: $0) } ?? "")
    }

    /// Locale-aware byte size formatting (used by readiness/UI).
    public static func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Locale-aware duration formatting (seconds -> localized).
    public static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: seconds) ?? "\(seconds)s"
    }

    // MARK: - Technical identifiers (never localized)

    /// Keys/values that must NEVER be translated: model IDs, bundle IDs,
    /// paths, file names.
    public static let protectedIdentifiers: Set<String> = [
        "ZephyrFlow", "ZephyrFlowCore", "openai_whisper-tiny", "openai_whisper-base",
        "openai_whisper-small", "apple-speech", "com.zephyrflow.history-key",
        "~/Library/Logs/ZephyrFlow/", "Hugging Face", "AES-256-GCM",
    ]

    public static func isProtected(_ value: String) -> Bool {
        protectedIdentifiers.contains(value)
    }

    // MARK: - Pseudolocalization / RTL readiness

    /// Pseudolocalization: expands strings (length probe) and wraps with
    /// marker characters so clipped controls are detectable in layout tests.
    public static func pseudolocalize(_ value: String) -> String {
        "⟦"
            + value
            .replacingOccurrences(of: "a", with: "å")
            .replacingOccurrences(of: "e", with: "ë")
            .replacingOccurrences(of: "i", with: "ï")
            .replacingOccurrences(of: "o", with: "ö")
            .replacingOccurrences(of: "u", with: "ü")
            .replacingOccurrences(of: "n", with: "ñ")
            .appending("⟧")
    }

    /// Long-string probe for the most critical UI surfaces: every key
    /// expanded ~1.8x (approximates German/pseudolocale) — layout tests can
    /// assert critical controls do not clip.
    public static func longProbe(_ value: String) -> String {
        let repeated = value.split(separator: " ").map { $0 + " " + $0 }.joined(separator: " ")
        return pseudolocalize(repeated)
    }

    /// RTL readiness: catalog must contain no layout-breaking constructs in
    /// the probe (mirroring check is a UI concern; this asserts data purity).
    public static func rtlProbeReady(_ value: String) -> Bool {
        // No hard-coded leading punctuation that breaks RTL mirroring.
        !value.hasPrefix("→") && !value.hasPrefix("⌘") && !value.hasPrefix("⌥")
    }
}
