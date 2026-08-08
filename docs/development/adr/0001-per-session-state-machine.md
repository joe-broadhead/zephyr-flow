# ADR 0001 — Per-session state machine, cancellation and generation

**Date:** 2026-08-08 (run 20260808T103416Z)
**Source:** JOE-2242 · milestone M0
**Status:** Accepted; implementation JOE-2246+

## Context

Dictation sessions previously coupled control events with long-running
preparation/inference and used mutable global state for the active engine,
making release/cancel queue behind model load and allowing stale callbacks to
mutate later sessions. We need one legal lifecycle for a session.

## Decision

1. **Immutable `SessionID`** is allocated before any asynchronous preparation
   begins. Every callback, event and state publication carries its SessionID.
2. **Independent control plane**: user release/cancel/shutdown events are
   handled by the session actor on a separate path and never queue behind
   preparation or inference.
3. **Generation semantics**: each session carries a monotonic generation; a
   late callback or completion from an older generation is rejected (token +
   generation check) before it can touch UI, history, metrics or engine state.
4. **State machine**: the `SessionState` + `SessionTransition` table (below) is
   the only legal transition map. Terminal states are absorbing. Exactly one
   terminal outcome is emitted via `SessionTerminalGate`.
5. **Ownership**: each session owns its capture resources, engine operation
   handle, pasteboard snapshot and Flow job for its entire lifetime; resources
   are released at terminal transition, never by a later callback.
6. **Timeouts**: each stage carries a monotonic deadline; exceeding it
   transitions to `deadlineExceeded` (never ordinary success).

Rejected alternatives:

- Global `activeEngine` lookups (stale callback hazard) — rejected.
- Boolean decode gates with polling (race between cancel and in-flight
  inference) — rejected by JOE-2250.
- Keeping the current singleton structure — rejected (JOE-2243).

## Transition table

States: idle → preparing → capturing → draining → transcribing →
transforming → resolvingTarget → inserting → terminal.

| From | Event | To |
|------|-------|----|
| idle | begin | preparing |
| idle | cancel / stop | stay (idempotent) |
| idle | shutdownRequested | abandonedDuringShutdown |
| preparing | readyToCapture | capturing |
| preparing | preparationFailed | failed |
| preparing | cancel | cancelled |
| preparing | shutdownRequested | abandonedDuringShutdown |
| preparing | deadlineViolated | deadlineExceeded |
| capturing | stop | draining |
| capturing | captureFailed | failed |
| capturing | cancel | cancelled |
| capturing | begin | stay (duplicate press) |
| capturing | shutdownRequested / deadlineViolated | abandoned / deadlineExceeded |
| draining | drainFinished | transcribing |
| draining | cancel / shutdownRequested / deadlineViolated | cancelled / abandoned / deadlineExceeded |
| transcribing | transcriptionFinished | transforming |
| transcribing | transcriptionFailed | failed |
| transcribing | cancel / shutdownRequested / deadlineViolated | cancelled / abandoned / deadlineExceeded |
| transforming | transformationFinished | resolving |
| transforming | transformationFailed | failed |
| transforming | cancel / shutdownRequested / deadlineViolated | cancelled / abandoned / deadlineExceeded |
| resolving | targetValidationSucceeded | inserting |
| resolving | targetChanged / targetSecure / targetUnknown | targetChanged / secureTarget / secureTarget(fail-closed) |
| resolving | cancel / shutdownRequested / deadlineViolated | cancelled / abandoned / deadlineExceeded |
| inserting | insertionSucceeded | completed |
| inserting | insertionFailed | failed |
| inserting | cancel / shutdownRequested / deadlineViolated | cancelled / abandoned / deadlineExceeded |
| terminal | any | **illegal** (absorbing) |
| idle | any other | stay/reject |

## Shutdown semantics

1. Close new-session/hotkey admission.
2. Cancel the active session via the control plane.
3. Stop and drain audio; quiesce engines; release resources; emit
   `abandonedDuringShutdown` for anything unfinished (JOE-2266).

## Validation

- `SessionState.swift` encodes the table; property tests iterate state×event
  and assert legality + exactly-one-terminal (JOE-2292 model-based tests).
- Randomized edge-sequence tests and 10,000 rapid press/release cycles
  (JOE-2257 stress) retain seeds.
