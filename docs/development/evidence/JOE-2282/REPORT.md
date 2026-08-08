# JOE-2282 — capability-based onboarding

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/CapabilityOnboarding.swift`, AppKit-free)

- `OnboardingCapability`: microphone / speechRecognition / accessibility /
  modelAcquisition / networkModelDownload / networkUpdateCheck /
  clipboardDisclosure / systemDictation / languageAvailability /
  localOnlyImplications.
- `OnboardingStep`: id, capability, title, explanation,
  requiresSystemPrompt, networkClass (none/modelDownload/updateCheck —
  network actions listed separately from audio privacy), skippable.
- `OnboardingProductPath`: WhisperKit automatic / clipboard-only, Apple
  Speech automatic / clipboard-only.
- `CapabilityGraph.steps(for:)` — deterministic sequence per path. Rules:
  WhisperKit paths NEVER request Speech Recognition or System Dictation;
  clipboard-only paths never imply Accessibility is required; network
  actions are separated from audio privacy. `remainingSteps` (delta — only
  missing capabilities), `isComplete`, `skipExplanation` (limitations +
  recoverable), `path(model:insertionMode:)`.

## App wiring

- `AppSettings.completedCapabilities: [String]` persisted (NOT just
  `hasCompletedOnboarding`); backward-compatible custom `init(from:)` so old
  payloads decode with the new field defaulting to [].
- `OnboardingView` rewritten graph-driven: steps derive from the current
  product path; already-granted capabilities auto-skip WITHOUT hiding
  required system switches; every system prompt follows a user action with an
  explanation; missing/denied capabilities stay on an actionable step (or
  skip states limitations + recoverability); network/model-download consent
  is its own explained step; skip notes are shown; finish persists completed
  capabilities and derives the onboarding boolean from graph completeness.
  Flow remains keyboard/VoiceOver navigable (buttons, .keyboardShortcut,
  accessibility labels).

## Acceptance criteria

- All supported engine/insertion combinations have deterministic step
  sequences — tests over all 4 paths.
- No system prompt before a user action + explanation — prompt steps carry
  explanation; prompts fire only from primary action.
- Already-granted capabilities skipped without hiding required switches —
  test 9.
- Missing/denied capabilities lead to actionable limited modes — skip
  explanations test 10.
- Flow is keyboard/VoiceOver navigable — UI keeps shortcuts + labels.

## Deterministic tests (33 JOE-2282 checks)

Deterministic+no-dup per path; WhisperKit never requests speech/system
dictation; clipboard-only no accessibility; automatic includes accessibility;
network class separation; delta requests only missing; completeness; path
derivation; every skip explains+recoverable; prompts explained; granted
skip vs required prompts remain; AX skip offers copy mode. All pass.

## Remaining manual validation (human gate)

UI recordings for fresh/partial/existing installs + permission-denied and
language-pack-missing paths on a real machine — runbook retained.
