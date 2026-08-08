# JOE-2272 — no-side-effect review UX for changed/unknown/secure targets

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core model (`Sources/ZephyrFlowCore/InsertionReviewModel.swift`, AppKit-free)

- `InsertionReviewAction`: retryValidation / explicitCopy / discard /
  openAccessibilitySettings.
- `InsertionReviewModel(outcome:createdAtNanos:retentionNanosAhead:)`:
  - plain-language `title` + `detail` per uncertainty outcome (no AX jargon,
    no content);
  - `allowsRetry` only for resolvable outcomes (targetChanged, targetGone,
    notEditable, deadlineExceeded); NEVER for targetUnknown (missing
    permission) or secureTarget (never auto);
  - `allowsCopy` always (explicit only), `shouldWarnBeforeCopy` for
    secure/unknown (global-clipboard warning);
  - `allowsOpenAccessibilitySettings` only for targetUnknown;
  - bounded retention (30 s default) with `expired(nowNanos:)`;
  - single-shot `consume(action:)`; `clear(reason:)` incl.
    retriedWithFreshIntent / userDiscarded / userCopied / expired.
- No uncertain state auto-pastes, auto-copies or auto-dismisses as success:
  `isUncertain` mirrors `InsertionOutcome.isUncertain`; green UI is denied by
  outcome policy (JOE-2269).

## Controller (`DictationController`)

- All five uncertainty outcomes (targetChanged/gone/unknown/secureTarget/
  notEditable) + deadlineExceeded now route to `presentReview(outcome:text:)`
  (persistent panel, controlled reason, no green success) instead of a bare
  error.
- `retryReview()`: consumes `.retryValidation`, then starts a FRESH session
  (new SessionID via control.begin), captures a FRESH TargetSnapshot,
  re-evaluates sensitivity and runs a new validation + insert. Never reuses a
  stale validation; retry with no AX / secure re-routes to review again.
- `discardReview()` clears text + model (policy: in-memory text cleared).
- `openAccessibilitySettings()` opens onboarding/settings for targetUnknown.
- History remains gated by final outcome policy (JOE-2269) + sensitivity.

## Panel (`FloatingPanel`)

- Review panel shows title + detail (plain language), action buttons:
  Retry (⌘R, only when allowed), Copy / "Copy to Clipboard" (warned label for
  secure/unknown), Settings (only for targetUnknown), Discard (Esc).
- VoiceOver/accessibility labels on every control; keyboard shortcuts; clear
  "Clears automatically in 30s" retention text.
- Esc in reviewing state now calls discardReview (clears text + model).

## Acceptance criteria

- No uncertain state auto-pastes/auto-copies/auto-dismisses as success — by
  construction + outcome policy.
- User can understand what happened without technical AX terminology —
  plain-language title/detail.
- Retry cannot insert into a different target without explicit fresh intent —
  retry captures fresh snapshot + fresh validation + new session; no stale
  reuse.
- Secure/unknown copy is always explicit and clearly warned — warned copy
  label + explicit button.
- Dismiss/discard clears in-memory text per policy — discardReview clears
  SecureSessionReview content + model.

## Deterministic tests (JOE-2272 block)

Per-outcome availability matrix (retry/copy/discard/settings), plain-language
title/detail, expiry + retention, single-shot consume, retry refused for
secure, settings allowed only for unknown, discard clears. All pass.

## Remaining manual validation (human gate)

VoiceOver/keyboard review and dogfood recordings for app-switch and
permission-loss scenarios — real-device items with runbook below.

### Runbook (human gate)

1. Dictate in app A, Cmd-Tab to B mid-speech, release → review panel
   "The target changed" with Retry/Copy/Discard; Retry must re-validate fresh.
2. Disable Accessibility, dictate → "Target could not be confirmed" with
   Settings link; Copy warns.
3. Dictate into a password field → "Secure field detected", copy warned.
4. VoiceOver: tab through buttons, verify labels; keyboard: ⌘R retry,
   Esc discard, Return copy.
