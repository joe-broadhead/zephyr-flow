# JOE-2256 — generation-safe model selection and preload

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/ModelSelection.swift`, AppKit-free)

- `ModelLoadOutcome`: ready / failed(model,message) / cancelled / superseded
  (typed — stale completions are never generic failure banners).
- `ModelSelectionTracker`: monotonic request ids; `submit` supersedes any
  in-flight request and snapshots settings at request start;
  `acceptCompletion` publishes ONLY when the request is current — every stale
  completion becomes a typed `.superseded(byRequestID:)` and cannot overwrite
  a current ready/failed state; `cancelCurrent`; `allowsSessionStart(model:)`
  — a session may only start against the CURRENT selection (never an engine
  that finished loading for an obsolete choice).

## App wiring

- `ModelReadinessStore`: `select(model:allowDownloads:localOnly:)` returns the
  request id and cancels in-flight load tasks for older selections;
  `publishLoadCompletion(requestID:model:outcome:)` publishes ONLY current
  completions (ready banner / typed failure / cancelled / superseded=no-op).
- `DictationController.preloadEngine`/`reloadEngine`: both route through the
  tracker; sessions capture their engine identity at start (JOE-2249
  binding), so switching models during active dictation never affects the
  active session — the next session uses the accepted new engine.

## Acceptance criteria

- Rapid A->B->A cannot end with B active or B's error banner displayed —
  tracker tests (last request current; stale completions superseded).
- Old completion cannot overwrite current ready/failed state — test 3.
- Active sessions retain their engine/model identity — session engine
  binding from JOE-2249; session-start guard test 4.
- Load cancellation/supersession releases tasks without use-after-free —
  `select` cancels older load tasks; typed cancelled/superseded states.
- Readiness UI deterministic under injected out-of-order completion —
  permutation test 8.

## Deterministic tests (13 JOE-2256 checks)

A->B->A current; stale A/B superseded; current accepted; stale failure cannot
publish; session-start guard (current yes, obsolete no); cancel clears;
monotonic ids; settings snapshot; out-of-order matrix. All pass.

## Remaining manual validation (human gate)

Rapid model switching in the running app with a real engine load — runbook
retained.
