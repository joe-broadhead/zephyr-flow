# JOE-2250 — WhisperKit exclusive cancellable decode ownership

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/DecodeOwnership.swift`, AppKit-free)

- `DecodePurpose` (partial/final), `DecodeOperation` (operationID, purpose,
  SessionID, startedAt, deadline), `DecodeOperationOutcome` (completed /
  cancelled / deadlineExceeded / degraded — controlled taxonomy).
- `DecodeOwnership` (replaces Boolean + sleep polling):
  - exclusive `begin` (nil while busy; rejectedWhileBusy counted);
  - `finish` releases ownership ONLY for the current owner (native call ended);
  - `cancel` marks the outcome but RETAINS ownership until finish — a new
    decode cannot start while the instance is still busy;
  - `timeoutIfExpired` records the typed deadline outcome but does NOT clear
    the gate (native inference still executing);
  - `maxObservedConcurrency` instrumented (always ≤ 1);
  - `reusable` only after the prior operation ended.
- `FakeDecode` deterministic adapter (controllable start/end, concurrency
  recording) for race/stress tests.

## App wiring (`WhisperKitEngine`)

- `decodeInFlight` + `waitForDecodeIdle` sleep polling REMOVED.
- `runTranscribe(kit:samples:options:purpose:)` begins a `DecodeOwnership`
  operation, runs the native call, finishes on completion/degraded, cancels +
  finishes on cancellation. `waitForDecodeIdle` waits for ownership release
  (deadline noted but gate retained; hard-cap backstop logs loudly and NEVER
  clears ownership).
- `startStreaming(sessionID:localOnly:onPartial:)` — protocol now threads the
  immutable SessionID (JOE-2249/2250) into both engines; partial loop uses
  `purpose: .partial`, finalize uses `purpose: .final`; finalize waits for the
  owned partial to END and never starts a second decode after a cap.
- Teardown/cleanup resets ownership only after quiescence.

## Acceptance criteria

- Concurrency instrumentation proves max simultaneous transcribe == 1 —
  `maxObservedConcurrency` + 10k-race test.
- Deliberately stuck fake decode cannot cause a second decode after timeout —
  timeout retains ownership (tests).
- Final and cancel paths do not deadlock and do not clear ownership early —
  cancel retains until finish; finish releases exactly once (tests).
- Engine reusable only after prior operation ended — `reusable` gating tests.
- All operation outcomes map to the controlled taxonomy — completed/cancelled/
  deadlineExceeded/degraded.

## Deterministic tests (JOE-2250 block)

Exclusive begin/reject-while-busy; deadline keeps ownership + blocks second
decode; stranger cannot finish; owner finish releases once; cancel retains
until native end; stuck decode blocks second decode then releases after
finish; 10,000 partial/final race iterations stay single-flight with
maxObservedConcurrency == 1. All pass.

## Remaining manual validation (human gate)

Real WhisperKit stress (long dictations, rapid cancel/final) + retain
max-concurrency and cancellation/deadline reports (runbook retained).
