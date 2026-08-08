# JOE-2283 — first-run model acquisition UX

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/ModelUIPolicy.swift`, AppKit-free)

- `ModelLifecycleUIRender` for every verified state (missing/queued/
  downloading/verifying/ready/cancelled/quarantined/failed): state name,
  honest-progress flag (bytes/fraction only when REAL), indeterminate flag,
  primary action (cancel/retry/choose another model/use Apple Speech/
  continue limited), recoverable, blocksDictation.
- `mayStartDownload(consent:hasCachedVerifiedModel:freeBytes:)` gate:
  cached verified model starts from cache; no consent -> consentRequired;
  insufficient disk -> typed insufficientDiskSpace; else allowed.
- `cleanupGuidance` — actionable free-space guidance (locale-aware sizes).
- `absorbCompletion` — superseded completions are UI no-ops (JOE-2256).

## App wiring

- `DictationController.beginSession`: explicit guard — a dictation attempt
  while the selected model is not ready NEVER enters fake listening/
  capturing (shows an actionable error instead).
- `ModelReadinessStore.freeDiskSpace()` — preflight volume capacity.
- Lifecycle states rendered in the Settings Model section (JOE-2255 states);
  cancel/retry/choose-model/Apple-Speech paths recoverable without restart.

## Acceptance criteria

- Empty-cache first run has no unexplained network call / ambiguous mic
  state — consent gate + honest indeterminate progress; dictation blocked
  until verified ready.
- Failed/cancelled downloads recoverable without restart — retry actions.
- Verification is a visible state distinct from download completion —
  render tests.
- Apple Speech fallback explains Local Only/language-pack behavior —
  capability graph (JOE-2282) + policy actions.
- UI survives quit/relaunch and resumes/cleans partial work — verified
  cache contract (JOE-2255) + stale-lock cleanup.

## Deterministic tests (23 JOE-2283 checks)

Render for every state; dictation-blocking rules; honest vs indeterminate
progress; download gate (cache/consent/disk/allowed); cleanup guidance;
cancelled/quarantined recoverable with retry; verifying distinct; superseded
absorbed. All pass.

## Remaining manual validation (human gate)

Recorded fresh-install flows under fast/slow/offline/corrupt/disk-full/
cancelled conditions on a real machine — runbook retained.
