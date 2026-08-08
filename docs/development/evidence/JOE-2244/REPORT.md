# JOE-2244 — UI split: session truth in one isolated per-session actor

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/DictationSession.swift`, AppKit-free)

- `DictationSession` actor: ONE isolated actor per session owning the control
  plane (`SessionControlModel`), stage sequencing, mutable session state and
  exactly-once terminal release. Constructed with immutable inputs: engine
  choice, settings snapshot and a per-session stage provider; SessionID is
  allocated from a SHARED `SessionIDFactory` (monotonic, lock-protected) so
  two successive sessions can never collide on identity.
- `SessionStateBroadcaster<State>`: replay-latest multicast stream — UI
  subscribers can reconnect at any time without changing session state.
- Typed read-only `SessionUIState` + explicit stage outputs
  (`SessionStageOutputs`: audio summary, engine result, Flow outcome, target
  validation, insertion outcome).
- `DictationSessionStageProviding` protocol: leaf I/O (prepare/startCapture/
  stopCapture/finalize/applyFlow/validateTarget/insert/recordHistory/cancel);
  sequencing stays in the actor. Deterministic fakes drive end-to-end tests
  with NO SwiftUI/AppKit.
- `SessionControlModel.begin(sessionID:)`: admit a factory-unique id.

## App wiring

- `ProductionSessionStages` (new): per-session production provider — owns the
  session-scoped bounded audio channel, delivery task, converter, frame
  accounting, drain barrier, callback gate and engine binding (logic moved
  out of the controller).
- `DictationController` rewritten as a THIN MainActor UI projection: creates a
  fresh provider + actor per Fn press, subscribes to the typed state stream,
  maps states to @Published panel fields, and forwards user review actions
  (retry/discard) to the actor. App-level responsibilities preserved outside
  the domain actor: permission prompts, settings/onboarding opening, hotkey,
  engine preload, review UI, termination handshake.

## Acceptance criteria

1. UI coordinator contains no business-critical sequencing or session-
   generation race logic — sequencing lives in `DictationSession.run()`.
2. Two successive sessions cannot share mutable tasks, buffers, target
   identity or callbacks — distinct actor + provider per session, shared
   monotonic `SessionIDFactory`, fresh `CallbackGate` per session.
3. Tests drive a session end-to-end without SwiftUI/AppKit — `FakeSessionStages`.
4. UI subscribers reconnect without changing session state — broadcaster
   replay test.
5. Session deinitialization/leak test shows all owned tasks/callbacks
   released — weak-ref test after terminal.

## Deterministic tests (JOE-2244 block, 23 checks)

Success end-to-end (interim, audio summary, engine result, flow, validation,
insertion, history exactly once); no second terminal side effects; cancel
mid-capture (provider cancelled, no history); target-change -> review ->
retry -> success; partial transcript -> warning (no history); reconnect replay;
successive sessions distinct ids (shared factory); leak/deinit after terminal.
All pass.

## Files
- Sources/ZephyrFlowCore/DictationSession.swift (new)
- Sources/ZephyrFlowCore/SessionControl.swift (begin(sessionID:))
- Sources/ZephyrFlow/Services/ProductionSessionStages.swift (new)
- Sources/ZephyrFlow/Services/DictationController.swift (thin rewrite)
- Tests/ZephyrFlowCoreTests/main.swift (JOE-2244 block)
