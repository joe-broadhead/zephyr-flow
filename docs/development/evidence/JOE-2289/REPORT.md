# JOE-2289 — localization-ready strings

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/AppStrings.swift`, AppKit-free)

- Semantic string catalog: stable keys with translator context (52 keys
  covering onboarding, settings, panel/review, menu bar); English fallback
  for missing translations; unknown keys resolve to the key (surfaced by CI).
- `format(key:args:)` parameterized strings (no concatenation of
  grammar-sensitive fragments); `byteSize`/`duration` use locale-aware
  formatters.
- `protectedIdentifiers`: model IDs, bundle IDs, paths, app name never
  localized.
- `pseudolocalize` (diacritics + markers) and `longProbe` (~2x expansion) for
  layout tests; `rtlProbeReady` checks catalog purity for RTL readiness.
- `OnboardingStep` carries `titleKey`/`explanationKey` (graph semantics
  localization-ready; UI resolves via AppStrings).

## App wiring

- All hard-coded user-facing strings migrated in SettingsView,
  FloatingPanel, MenuBarView, OnboardingView to AppStrings lookups.
- UI locale is independent of the selected transcription language: the
  Language picker drives `SupportedLanguage` (engine-capability matrix,
  JOE-2254) and never touches UI strings.
- `Scripts/string_scan.py` — CI completeness gate: scans production UI for
  unreviewed hard-coded strings (allowlist only for technical punctuation)
  and verifies every AppStrings reference resolves to a catalog key. Added
  to `Scripts/ci_checks.sh` gate 4.

## Acceptance criteria

- Repository scan finds no unreviewed hard-coded user-facing strings in
  production UI paths — string_scan passes (52 keys, all refs resolve).
- UI locale changes do not silently change transcription language — Language
  picker is transcription-only (matrix tests).
- Transcription-language options match the supported matrix — BCP-47 test.
- Long/pseudolocalized strings do not clip critical controls — longProbe +
  pseudolocalization tests (layout screenshots retained for human gate).
- Errors/accessibility labels semantically aligned with typed outcomes —
  catalog carries review/error labels; typed outcome mapping unchanged.

## Deterministic tests (JOE-2289 block)

Key resolution + fallback; context/value completeness for every key;
transcription matrix (Auto + BCP-47); pseudolocalization expansion;
long probe; protected identifiers; RTL readiness; parameterized format;
onboarding step keys resolve; locale-aware byte/duration formatting.
All pass.

## Remaining manual validation (human gate)

Pseudolocalization and RTL screenshots for critical surfaces (onboarding,
settings, panel/review) on a real machine — runbook retained.
