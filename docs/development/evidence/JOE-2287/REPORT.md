# JOE-2287 — one serial deduplicated hotkey edge stream

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`
**Provisional assumption:** Fn/Globe remains the default; the engine serves all
hotkey shapes (Fn, right modifiers, standard chords) through ONE stream.

## Core (`Sources/ZephyrFlowCore/HotkeyEdgeStream.swift`, AppKit-free)

- `HotkeySourceEvent`: compact timestamped source event (source
  tap/global/local, down, keyCode, flags, isFnKey, isAutorepeat, monotonic
  timestamp) — raw CG/NSEvent callbacks never do edge logic.
- `HotkeyEdgeStream`: exactly ONE serial edge-state machine. Source priority
  (tap > global > local) + 30 ms dedup window → one physical action = one
  logical press/release pair across all enabled sources.
- Explicit handling: autorepeat (never edges), modifier chords (Fn+Cmd/Alt/
  Shift/Ctrl suppressed, state resets on chord release), side-specific right
  modifiers (keyCode-scoped), lost release (bounded 2 s sweep → auto-release;
  never arms hold/toggle permanently), tap-disabled events (surfaced by the
  consumer as degraded, no busy loop), config changes (reset held state
  safely, future events only).
- Lifecycle `stopped/starting/healthy/degraded/stopping` observable; stopping
  releases held state.
- All mutable state lives in the value type — no `@unchecked Sendable` in Core.

## App wiring (`Sources/ZephyrFlow/Services/HotkeyService.swift`)

- NSEvent global/local monitors + CGEvent tap all `feedRaw` into the ONE
  stream; `onEdge` fires only on logical edges (duplicates absorbed).
- `stop()`: real run-loop/thread completion signal (DispatchSemaphore) with a
  BOUNDED join outcome (replaces the fixed 0.5 s polling loop; join timeout
  surfaces degraded status).
- Lifecycle published as `lifecycleState`; lost-release sweep timer (0.5 s,
  consumer-side) recovers held state.
- Remaining `@unchecked Sendable` boundary: the CGEvent-tap C callback
  capturing the engine object — all mutable hotkey state is isolated inside
  the locked `HotkeyEdgeStream` value; plumbing refs (tap/runloop/monitors)
  are guarded by the same lock. Documented, no other unsafe boundary.

## Acceptance criteria + deterministic tests (20 JOE-2287 checks)

- One physical action → exactly one logical edge pair under all three
  sources (dedup window) — ✓
- Lost/duplicate/out-of-order raw events cannot leave hold/toggle armed
  (sweep recovery; duplicate down suppressed; stray release suppressed) — ✓
- Autorepeat + modifier chords never arm state; chord release resets — ✓
- Lifecycle: stopped ignores; stopping releases held; degraded processes —
  ✓
- Config change resets held state and affects future events only — ✓
- Stop: bounded join outcome (thread semaphore) — ✓ (code-level; real
  keyboard qualification is human-gate)

## Remaining manual validation (human gate)

Real laptop/external keyboard/layout, sleep/wake, permission-revocation
qualification + thread/concurrency sanitizer coverage — runbook in the
human-gate pass.
