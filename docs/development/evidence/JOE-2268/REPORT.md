# JOE-2268 — transactional target revalidation before insertion

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## What was delivered

Automatic insertion is now transactional: the app must prove the current
destination is the captured intended target (PID / process-start identity /
window / element token / role-subrole / editability / sensitivity) before any
AX write, pasteboard mutation or synthetic key event.

### Core (deterministic, unit-tested) — `Sources/ZephyrFlowCore/TargetRevalidation.swift`

- `TargetValidationOutcome`: `validated`, `targetChanged`, `targetGone`,
  `targetUnknown`, `secureTarget`, `notEditable`, `deadlineExceeded`.
- `TargetValidationContext`: content-free current observation (pid, bundle,
  processStartUptimeNanos, windowID, element role/subrole/resolutionToken,
  settable/editable/enabled, sensitivity, nowNanos).
- `TargetValidationSession`: one-shot state machine with bounded deadline
  (deadlineNanosAhead); terminal outcomes are absorbing; expiry can never
  stall a session. Captures `effectiveSensitivity` (most restrictive of
  captured vs current) and `upgradedBeforeInsertion`.
- `TargetRestoreMonitor`: bounded, observable restore monitor (pending →
  restoring → restored/rejected) with attempt cap + deadline; replaces the
  blind-sleep restore. `poll(isFrontmost:nowNanos:)` returns
  `.polling/.restored/.rejected/.deadlineExceeded`.
- `SessionSensitivity.mostRestrictive`: strictness ordinal
  normal(0) < secure(1) < unknown(2); unknown is most restrictive (fail-closed).

### App AX service — `Sources/ZephyrFlow/Services/TargetValidationService.swift`

- `captureSnapshot(sessionID:nowNanos:)`: AX-trusted capture of the focused
  user-facing target. Never targets Zephyr itself or ignored system processes
  (loginwindow, SecurityAgent, notificationcenterUI, controlcenter,
  systemuiserver, Spotlight, dock). No AX permission ⇒ nil ⇒ fail-closed
  unknown.
- `currentContext(nowNanos:)`: re-resolve immediately before insertion
  (same content-free fields).
- `restoreToCapturedTarget(snapshot:)`: activates the saved app exactly once,
  then polls `TargetRestoreMonitor` (50 ms steps, bounded) until restored /
  rejected / deadlineExceeded. No blind sleep.
- AX identity: `AXIsProcessTrusted`, `AXUIElementCreateApplication`,
  `kAXFocusedUIElementAttribute`, role/subrole/identifier, settable via
  `AXUIElementIsAttributeSettable`, enabled via `kAXEnabledAttribute`,
  window id via `CGWindowListCopyWindowInfo` (bounds only), process start via
  `proc_pidinfo(PROC_PIDTBSDINFO)` for PID-reuse detection.

### Controller wiring — `Sources/ZephyrFlow/Services/DictationController.swift`

- beginSession: captures the immutable snapshot at session start; derives
  `sessionSensitivity` from it; removes the stale `lastBundleID` fallback.
- endSession (normal path): `TargetValidationSession` started with a 2 s
  bounded deadline; bounded restore; re-resolved context; single decision:
  - `.validated` → `targetValidationSucceeded` → insertion (sensitivity =
    effective most-restrictive) → insertionSucceeded/insertionFailed;
    history write only when `historyWriteAllowed(effectiveSensitivity)`.
  - `.targetChanged/.targetGone/.notEditable` → terminal `.targetChanged`,
    zero side effects.
  - `.targetUnknown` / `.secureTarget` → terminal `.targetUnknown` /
    `.secureTarget`, review-only panel (explicit copy, no auto paste/AX/history).
  - `.deadlineExceeded` → terminal `.deadlineViolated` event.
- 2259 fail-closed branch restored: sessions whose sensitivity is
  secure/unknown skip structural/semantic Flow entirely and go straight to the
  review surface (explicit copy only).

## Acceptance criteria status

- **Cmd-Tab/field switch during dictation prevents automatic insertion** —
  deterministic fakes: windowReplaced/elementReplaced/focusSwitched →
  targetChanged; validated only on identical context. ✔ (deterministic)
- **App termination/relaunch with reused bundle/PID cannot receive stale
  text** — deterministic fakes: processGone/pidReuse → targetGone;
  bundleChanged → targetChanged. ✔ (deterministic)
- **No Accessibility permission produces unknown/no automatic side effect** —
  capture nil ⇒ unknown ⇒ review-only. Deterministic fake: nil context ⇒
  targetUnknown. ✔ (deterministic)
- **Secure reclassification prevents paste/AX/history** — secure captured or
  secure current ⇒ secureTarget, no side effects; history gate. ✔ (deterministic)
- **Validation has a bounded deadline and cannot block indefinitely on a hung
  app** — TargetValidationSession deadline + TargetRestoreMonitor cap. ✔

## Deterministic evidence (Tests/ZephyrFlowCoreTests/main.swift, JOE-2268 block)

All 20+ checks pass: identical-context validated; single-shot idempotent;
windowReplaced/elementReplaced/focusSwitched → targetChanged;
processGone/pidReuse → targetGone; bundleChanged → targetChanged;
notSettable → notEditable; secure reclass (current secure, current unknown,
captured secure) → secureTarget; no-AX → targetUnknown; deadline →
deadlineExceeded; mostRestrictive ordinal; restore monitor polling / restored /
deadlineExceeded / attempt-cap rejected.

## Remaining manual validation (real-device, honest gate)

- Real cross-window/field switch tests and target app exit/relaunch across
  multiple apps require a trusted AX environment and manual multi-window
  manipulation; runbook below.

### Runbook (human gate)

1. `./Scripts/build_app.sh debug && open Dist/ZephyrFlow.app`; grant
   Accessibility in System Settings → Privacy & Security.
2. Put caret in app A text field; Fn-hold dictation; during capture press
   Cmd-Tab to app B; release. Expect: "Target changed — insertion cancelled",
   no text in B.
3. Quit and relaunch app A while dictating; release. Expect: no stale text
   (targetGone/pidReuse path).
4. Disable Accessibility, dictate; release. Expect: review-only panel, no
   automatic insertion.
5. Dictate into a password (secure) field; release. Expect: review-only,
   no paste/history; explicit Copy writes clipboard with audit.
6. Verify logs contain outcome/reason lines only (no transcript content).
