# JOE-2284 — truthful UI for complete/partial/degraded/truncated + insertion confidence

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/UIStatePolicy.swift`, AppKit-free)

- `PanelSemanticState`: verifiedSuccess / unverifiedPosted / review / warning /
  error / processing / neutral.
- `PanelPresentation`: semantic state + title + message + autoDismissAfterNanos
  (nil = persistent) + colorToken + VoiceOver label + symbol — color is never
  the only signal.
- `UIStatePolicy.presentation(engineCompleteness:flowStatus:insertion:)`:
  - Green success ONLY for complete transcript + accepted flow +
    verifiedInserted (or explicit copy).
  - eventPostedUnverified → distinct "Paste sent — verify destination"
    (amber, never "Inserted").
  - partial/degraded/truncated → persistent warning/error, no auto-dismiss,
    no green.
  - flow rejection/deadline → visible warning (material style change).
  - target changed/gone/unknown/secure/notEditable → persistent review.
  - clipboard hygiene / deadline / cancelled / failed → distinct persistent
    warning/error/neutral.
- `isVerifiedSuccess` — no uncertain case shares it.

## App wiring (`DictationController` + `FloatingPanel`)

- Non-complete engine results (partial/degraded/truncated) short-circuit to
  persistent warning/error BEFORE the success path.
- Insertion presentation derives panel state/message/dismiss from the policy:
  `.warning` PanelState added (amber PanelWarningView with explicit Dismiss,
  Esc key, VoiceOver label; no auto-dismiss timer that erases recovery).
- `PanelState.warning` handled in the root switch + key monitor.

## Acceptance criteria

- Every EngineResult × FlowOutcome × InsertionOutcome combination maps through
  one tested policy — UIStatePolicy (tests).
- No uncertain case shares the verified-success presentation — tests.
- Status/color/icon/animation/VoiceOver convey the same semantic state —
  colorToken + voiceOverLabel + symbol on every presentation.

## Deterministic tests (JOE-2284 block)

Green only for complete+verified; unverified distinct; partial/degraded/
truncated persistent; flow fallback visible; review states persistent;
clipboard/deadline/cancel/fail distinct; no uncertain case green; VoiceOver
labels everywhere. All pass.

## Remaining manual validation (human gate)

VoiceOver/keyboard review of every state + dogfood recordings (runbook
retained).
