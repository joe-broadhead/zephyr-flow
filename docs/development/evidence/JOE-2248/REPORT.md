# JOE-2248 — audio stop/drain barrier + frame-accounting invariants

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/AudioDrain.swift` + `AudioChannel.swift`)

- `AudioFrameAccounting`: per-session counts only — capturedSourceSamples,
  convertedEngineSamples, deliveredEngineSamples, droppedSourceSamples,
  decodedEngineSamples + controlled `AudioDegradeReason` set (overflow,
  wrongSession, closedDrop, gap, reorder, drainTimeout, converterFailure,
  lateAppend, reconciliationMismatch).
- `reconciles(converterRatio:roundingToleranceSamples:)`: success invariant —
  delivered == converted (engine-rate exact), and converted ≈
  (captured − dropped) × ratio within the explicitly defined converter
  rounding tolerance. Any degrade reason ⇒ false (fail closed).
- `AudioDrainBarrier(deadlineNanosAhead:)`: EOS barrier over the final
  accepted producer sequence; deadline-aware (timedOut), cancellable, counts
  late appends AFTER drain acknowledgment (never silently cleared).
- `BoundedAudioChannel` now tracks sample-level drop counters
  (overflow/wrongSession/closedDroppedSamples), acceptedSamples and
  lastAcceptedSequence (EOS marker).

## App wiring (`DictationController`)

- Delivery task: notes captured samples per chunk; late/reordered chunks are
  counted (lateAppend) and skipped; converted+delivered noted on engine
  append; drainBarrier ticked per delivered sequence.
- endSession: after tap stop, `drainBarrier.begin(finalSequence:)` at the
  last accepted sequence; task drains through it; then channel stats folded
  into accounting (only non-zero drops degrade); reconciliation check with
  explicit ratio/tolerance; logs COUNTS ONLY (never payloads): accepted/
  captured/converted/delivered/dropped samples, drain state, lateAppends,
  reconciled flag.
- Any gap / overflow / drain timeout / late append / reconciliation mismatch
  ⇒ `.captureFailed` (degraded), never ordinary success.

## Acceptance criteria

- Last-buffer/last-word fixtures complete — barrier drains through final
  sequence (tests).
- Finalization waits for a deliberately delayed final chunk — barrier
  draining until sequence == final (tests).
- Any gap/overflow/drain-timeout yields degraded — accounting + barrier
  tests.
- No append accepted after final drain acknowledgment — channel closes at
  tap stop; late appends counted by barrier (tests).
- Cancel/shutdown release without deadlock/double finalization — barrier
  cancel terminal tests.

## Deterministic tests (JOE-2248 block)

300-run property test over randomized chunk sizes × converter ratios
(0.5/1.0/2.0/0.75) reconciles; dropped-samples degrade; delivered<converted
mismatch; exact + tolerance success; barrier draining→drained through final
sequence; drain timeout degrades; late append counted after ack; cancellation
terminal + no double-finalize; channel sample accounting + closed-drop
samples. All pass.

## Remaining manual validation (human gate)

Soak/real-device capture with long sessions and injected latency; retain
per-run frame-accounting evidence (runbook below).

### Runbook (human gate)

1. Dictate a long sentence; verify log shows reconciled=true with exact
   captured/converted/delivered counts.
2. Inject a slow conversion (simulate by pausing engine append) — verify
   drain timeout => degraded outcome, not complete.
3. Stop the tap mid-buffer repeatedly — verify counts always reconcile or
   the session is honestly degraded.
