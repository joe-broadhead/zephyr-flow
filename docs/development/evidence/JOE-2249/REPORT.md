# JOE-2249 — session-bound engine + callback gating

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SessionEngineBinding.swift`, AppKit-free)

- `EngineToken`: immutable engine-instance identity (UUID).
- `EngineKind`: whisper / appleSpeech (content-free classification).
- `SessionEngineBinding`: immutable sessionID + engineToken + engineKind
  captured at capture start.
- `CallbackGate`: single-shot gate (open → closed by cancelled /
  terminalOutcome / engineReplaced / drainCompleted); `accepts(binding:
  currentSessionID:currentEngineToken:)` validates the binding is still the
  current session AND the engine token is unchanged (engine replacement
  rejects in-flight callbacks). Close is idempotent (first reason wins).

## App wiring (`DictationController`)

- beginSession: captures `sessionEngineHandle = activeEngine` (immutable
  snapshot) + `SessionEngineBinding` + fresh `CallbackGate` per session.
- All delayed/async paths use the SESSION-captured engine
  (`sessionEngine ?? activeEngine`), never a mutable global lookup inside a
  delayed task: startStreaming, stopAndFinalize, cancel, delivery task.
- Partial-callback closure validates `callbackGate.accepts(binding:...)` +
  `control.isCurrent` before touching UI state — callbacks after
  cancellation/terminal/engine-replacement are rejected.
- Engine switches (whisper/apple) bump `currentEngineToken` + close the gate
  with `.engineReplaced` — reload affects only future sessions.
- endSession terminal closes the gate `.terminalOutcome` + releases
  `activeSessionBinding`/`sessionEngine`; stop() closes `.cancelled` and
  clears them — no indefinite retention.

## Acceptance criteria

- Switching selected model/engine mid-session cannot redirect pending PCM or
  results — session-captured engine + token gate (tests).
- Session A callbacks cannot reach session B — binding sessionID equality
  (tests).
- Cancellation removes callback references — gate closed + binding cleared.
- Leak: closures weak-self + binding/engine released at terminal/stop.
- No unstructured callback task reads mutable `activeEngine` — all async
  paths use the captured handle.

## Deterministic tests (JOE-2249 block)

Open gate accepts current binding; wrong session rejected; stale token after
replacement rejected; cancelled/terminal/drain gates reject later callbacks;
close single-shot. All pass.

## Remaining manual validation (human gate)

Thread/concurrency stress under rapid settings changes + stale-callback
rejection counter evidence (runbook in audio soak; retained for human gate).
