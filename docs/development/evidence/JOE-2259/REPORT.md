# JOE-2259 — secure/unknown sessions are review-only (no auto Flow/paste/history)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Domain enforcement (cannot be bypassed via direct service calls)

- `SensitiveSessionPolicy.conservativeStyle(for:)` — secure/unknown sessions
  route professional/bullets/summary to the conservative `clean` style;
  structural/semantic Flow never runs on them.
- `SensitivityPolicy` (JOE-2258) + `SensitiveSessionPolicy` gates:
  - `autoPasteAllowed` / `automaticInsertAllowed` — secure/unknown: false.
  - `clipboardFallbackAllowed` — secure/unknown: false.
  - `historyWriteAllowed` — secure/unknown: false.
- `InsertionService.insert(..., sensitivity:)` rejects at the domain layer
  (returns `.failed("Sensitivity policy blocks automatic insertion")`)
  before ANY pasteboard/AX side effect — a direct service call cannot bypass
  the UI.
- `DictationController` endSession only writes history when
  `historyWriteAllowed`; skip is logged by sensitivity class, never content.

## Review surface (in-process only)

- `SecureSessionReview` (Core): owns the text solely in memory with a bounded
  30 s review window; clear reasons: userDismissed, deadlineExpired,
  sessionCancelled, appTerminating, consumedByExplicitCopy.
- `DictationController.presentSecureReview` shows the `.reviewing` panel;
  auto-clear task fires at the deadline; cancellation/termination clear too.
- Explicit copy: `copyReviewContent()` — clipboard write happens ONLY after
  `consumeForExplicitCopy`, with a content-free `ExplicitCopyAuditRecord`
  (sensitivity class, upgraded flag, timestamp). The text is never logged.

## Fail-closed runtime posture (provisional, until target evidence wiring)

`sessionSensitivity` defaults to `.unknown` (fail-closed) until JOE-2268/2290
wire AX/TargetSnapshot evidence. Consequence while those land: every session
is review-only by design, exactly as required ("disabling Accessibility causes
unknown/fail-closed behavior rather than automatic paste"). The deterministic
unit tests drive policy with injected normal/secure/unknown decisions; the
runtime source wiring is the next dependency lane.

## Deterministic tests (JOE-2259 block in Tests/ZephyrFlowCoreTests/main.swift)

- review holds content in memory only; cleared at deadline; expired detection.
- cleared review cannot be copied; explicit copy returns content once,
  second copy refused; audit content-free.
- conservative style routing (professional/bullets/summary -> clean; clean/raw
  preserved).
- auto-paste/history fail-closed for secure & unknown; normal allows history.

## Verification

`swift run ZephyrFlowCoreTests` 0 · `swift build` 0 · `mkdocs build --strict` 0
