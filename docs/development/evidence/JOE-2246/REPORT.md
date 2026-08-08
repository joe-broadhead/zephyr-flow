# JOE-2246 — session control plane evidence report

**Date:** 2026-08-08 · Run 20260808T103416Z
**Branch:** agent/zephyr-production-run-20260808T103416Z

## What was implemented

- `Sources/ZephyrFlowCore/SessionControl.swift` — deterministic `SessionControlModel`:
  - immutable `SessionID` allocated before any async preparation (`begin()`);
  - control events (`begin`/`stop`/`cancel`/`shutdown`) act on the model
    synchronously — they never queue behind model load or inference (no stage
    FIFO on the control path);
  - per-session generation counter; late callbacks rejected via
    `isCurrent(_:)` (SessionID + non-terminal);
  - idempotent duplicate press/release/cancel edges (`.idempotentNoop`);
  - shutdown closes admission and abandons the active session honestly;
  - exactly-one terminal outcome via the M0 `StageOutcomeCategory` mapping.
- `Sources/ZephyrFlow/Services/DictationController.swift` — wired to the model:
  - SessionID guard on partial callbacks and every stage boundary;
  - release during model load now cancels the session (capture can never
    start later);
  - terminal stages recorded on the model (completed/failed/cancelled/…).

## Cancellation latency

Cancellation is a single synchronous transition on `SessionControlModel`
(`cancel()`/`stop()` in `.preparing` maps to `.cancelled`). There is no wait on
the stage FIFO: the control plane is a value-type state machine, and the app
paths that used to serialize begin/end behind `enqueueSession` long work now
check `control.isCurrent(sid)` after each awaited stage. Measured bound: one
`mutating` call (sub-microsecond in tests; wall latency dominated by the
hotkey callback dispatch, not by stage work).

## Stale-callback isolation

Tests in `Tests/ZephyrFlowCoreTests/main.swift` (JOE-2246 section):

- session A cancelled ⇒ `isCurrent(A)` false; a late A callback cannot update
  state;
- new session B after A's terminal ⇒ B current, A stale (identity values
  differ via monotonic sequence);
- late `stage(...)` events after terminal are rejected;
- 10,000 randomized press/release/cancel edges preserve invariants
  (absorbing terminal, no illegal duplicates, exactly-one terminal per
  session).

## Verification

| Check | Command | Result |
|-------|---------|--------|
| Core tests | `swift run ZephyrFlowCoreTests` | pass (exit 0), incl. all M0 + JOE-2246 blocks |
| Full build | `swift build` | pass (exit 0), app + WhisperKit deps |
| Docs | `mkdocs build --strict` | pass (exit 0) |

## Residual risks

- UI-level rapid-control evidence (real hotkey events) requires a real device
  session (JOE-2257); deterministic model coverage is retained here.
- Randomized property fuzzing with many more seeds belongs to JOE-2292's
  fakes laboratory.
