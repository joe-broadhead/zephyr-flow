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
    → stopAndFinalize → FlowRouter (Classic / Enhanced rules)
    → panel hide → FocusStore.restore
    → InsertionService (per-app strategy order)
    → HistoryStore
```

While listening (Whisper path), a **single-flight** rolling partial decode may update `interimText`.

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
| InsertionService | Per-app strategies (paste / AX / copy-only) |
| FocusStore | Frontmost app memory |
| DictationController | Orchestrator |
| FlowRouter + FlowProcessor | Post-STT cleanup (classic default) |
| EnhancedFlowProcessor | Opt-in enhanced deterministic **rules** (no LLM, no weights, no network) |
| FlowGuardrails | Reject novel numbers / preambles on Enhanced output |
| ModelReadinessStore / WhisperModelLocator | Cache status |
| UpdateChecker | On-demand GitHub Releases check |
| PrivacyService | TCC status |
| SettingsStore / HistoryStore | Persistence |
| WindowRouter | Settings + onboarding |

See [Privacy](../guide/privacy.md) and [Security](../operations/security.md) for product constraints. Audit dumps are not stored in-repo.
