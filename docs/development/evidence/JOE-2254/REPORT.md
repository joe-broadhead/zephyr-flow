# JOE-2254 — language selection + on-device capability checks

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/LanguageSupport.swift`, AppKit-free)

- `SupportedLanguage`: validated model — `.auto` + supported BCP-47 matrix
  (en-US/en-GB/de-DE/fr-FR/es-ES/it-IT/pt-BR/ja-JP/zh-CN/ko-KR/nl-NL/ru-RU/
  sv-SE/da-DK/nb-NO/fi-FI/pl-PL/tr-TR/hi-IN/ar-SA); `bcp47` (nil = auto),
  `displayName`, `fromLegacy(_:)` migration from free-form String.
- `LanguageCapabilityDecision`: supported / unavailable / autoDetection.
- `LanguageCapability`: whisperOnDevice / appleOnDevice / appleAvailable /
  missingPackMessage; `decision(for:)` per engine — fixed language with
  missing on-device support => unavailable (actionable), never a silent
  substitution; auto => engine auto-detection.

## App wiring

- `AppSettings.language` now `SupportedLanguage` (default `.auto`); legacy
  free-form strings migrated via `fromLegacy`.
- Protocol `startStreaming(sessionID:localOnly:language:onPartial:)` — the
  language is snapshotted into each session and passed to the chosen engine.
- WhisperKit: fixed language sets `DecodingOptions.language` +
  `detectLanguage:false`; auto keeps engine detection. Results carry
  languageRequested/detected.
- Apple Speech: recognizer constructed for the requested locale with an
  EXPLICIT fallback policy (unavailable locale/instance => actionable
  `modelLoadFailed`, never silent en-US); Local Only preflights
  `supportsOnDeviceRecognition` and fails with a language-pack message —
  never a silent network fallback. Results carry requested/detected language.
- Settings → Engine: validated language Picker (auto + matrix) with
  capability note; affects the NEXT session only.
- Changing the language never mutates an active session (snapshot at start).

## Acceptance criteria

- Changing language affects the next session predictably — snapshot per
  session + tests.
- Unsupported language/engine combinations are disabled or fail with an
  actionable message — capability decision + engine errors.
- Local Only never silently falls back to network — preflight + fail.
- Auto-detect and fixed-language have separate tests — decision + options.
- Result metadata reports requested + engine-used language — EngineResult
  fields.

## Deterministic tests (JOE-2254 block)

Auto/fixed BCP-47 matrix; legacy migration (valid/invalid/empty/auto);
capability decisions per engine incl. missing Apple pack and no-recognizer;
auto => autoDetection; snapshot semantics. All pass.

## Remaining manual validation (human gate)

Real-device checks for the supported locale matrix + missing language packs
(download/remove packs, verify preflight messaging; runbook retained).
