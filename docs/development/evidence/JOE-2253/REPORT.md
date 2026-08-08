# JOE-2253 — Apple Speech tokenized callbacks + event-driven finalization

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SpeechRecognitionTracker.swift`, AppKit/Speech-free)

- `RecognitionToken` (unique per start) + `SpeechFinalEvent` (finalResult /
  terminalError / cancelled / deadlineExceeded).
- `SpeechFinalizationOutcome`: finalResult / emptyFinalWithPartial /
  terminalErrorWithPartial / terminalErrorNoText / cancelled /
  deadlineWithPartial / deadlineNoText (no transcript bodies).
- `SpeechRecognitionTracker`: token identity + single final event; stale-token
  callbacks rejected (counted); empty final PRESERVES the latest usable
  partial with warning provenance; deadline with non-empty partial is
  partial-only (never complete); waiter resume exactly once (`markResumed`).

## App wiring (`AppleSpeechEngine`)

- startStreaming allocates a fresh RecognitionToken; the recognitionTask
  callback captures it and `handleRecognition(token:result:error:)` rejects
  stale tokens.
- `stopAndFinalize` is EVENT-DRIVEN: endAudio + await the final event
  (final result / terminal error / cancellation) up to a bounded 2 s deadline
  via withTaskGroup; never breaks early merely because partial text exists;
  deadline => `noteDeadline` (partial/degraded only).
- `finishRecognition()` — exactly-once terminal path called from EVERY
  terminal path (final result, error, cancel, stop, reload/shutdown):
  cancels/releases the task, ends audio, removes the tap, stops the engine,
  resumes waiters exactly once.
- `cancel()` uses the tracker cancel outcome + finishRecognition + cleanup.

## Acceptance criteria

- Delayed callbacks from a prior task cannot change current text/state —
  token rejection (tests).
- Finalization waits for a final event until deadline — event-driven wait
  (no early break on partial).
- Every terminal path cancels/releases the task and resumes waiters once —
  finishRecognition single path + markResumed (tests).
- Deadline/no-speech/system-disabled map to controlled outcomes — outcome
  taxonomy + tests.
- Repeated start/stop cycles do not leak tasks/taps — finishRecognition
  releases once per cycle.

## Deterministic tests (JOE-2253 block)

Stale-token partial/final rejection; current partial kept; empty final
preserves partial with provenance; terminal rejects later callbacks; error
with/without partial; deadline with/without partial (partial-only); waiter
resume exactly once. All pass.

## Remaining manual validation (human gate)

Fake-recognizer late/empty/duplicate/out-of-order callback soak + 1,000-session
Apple Speech leak/resource counters and deadline/final/partial outcome
distribution (runbook retained).
