# ZephyrFlow Architecture

## Modules

| Target | Responsibility |
|--------|----------------|
| `ZephyrFlowCore` | Models, protocols, `FlowProcessor` — no AppKit, unit-tested |
| `ZephyrFlow` | App shell, services, SwiftUI, optional WhisperKit |
| `ZephyrFlowCoreTests` | CLT-friendly privacy/logic checks |

## Session pipeline

```
HotkeyService (dedicated tap thread)
    → DictationController.beginSession
        → FocusStore.capture
        → FloatingPanel show
        → WhisperEngine.startStreaming  (WhisperKit default | AppleSpeech fallback)
        → FocusStore.restore (user keeps typing focus)
Hotkey release / Stop
    → stopAndFinalize → FlowProcessor
    → panel hide → FocusStore.restore
    → InsertionService (paste preferred, AX fallback)
    → HistoryStore
```

## Privacy controls

```
localOnlyMode (default true)           # audio/transcripts stay on-device
allowModelDownloads (default true)     # one-time Whisper model file fetch
mayDownloadModels = allowModelDownloads
```

Local Only does **not** block model-file downloads. WhisperKit is constructed with
`download: settings.mayDownloadModels` only (never unconditional `download: true`).

## File map (services)

| File | Role |
|------|------|
| HotkeyService + HotkeyTapEngine | Fn / modifiers |
| AppleSpeechEngine | Built-in STT fallback |
| WhisperKitEngine | Default STT (Whisper Tiny) |
| AudioCapture | PCM for Whisper path |
| InsertionService | AX + Cmd+V |
| FocusStore | Frontmost app memory |
| DictationController | Orchestrator |
| PrivacyService | TCC status |
| SettingsStore / HistoryStore | Persistence |
| WindowRouter | Settings + onboarding |

See [Privacy](../guide/privacy.md) and [Security](../operations/security.md) for product constraints. Audit dumps are not stored in-repo.
