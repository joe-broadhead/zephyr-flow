# JOE-2247 — bounded ordered audio channel evidence

**Run:** 20260808T103416Z · Integration branch `agent/zephyr-production-run-20260808T103416Z`

## Implementation

Core (`Sources/ZephyrFlowCore/AudioChannel.swift`):

- `AudioChunk` — owned contiguous samples bound to an immutable `SessionID`,
  with monotonic `sequence` and absolute `startSample`, sample-rate/channel
  metadata.
- `BoundedAudioChannel` — one producer (`enqueue` — synchronous, lock-guarded,
  bounded ring) and exactly one consumer (`chunks` AsyncStream). Overflow and
  wrong-session rejects are counted and surfaced (`stats()`, `isDegraded`),
  never dropped silently. Capacity is fixed at construction (256 chunks ≈ 21 s
  tail at 48 kHz / 4096-frame tap); memory is bounded for any recording length.
- `AudioChunkSequencer` — consumer-side order/skip guard: exact-order chunks
  accepted; gaps fast-forward+counted; late/reordered chunks counted and
  rejected (never appended downstream).

App wiring:

- `AudioCapture.start(sessionID:channel:)` — the real-time tap deep-copies the
  PCM and pushes one `AudioChunk`; no conversion in the callout, no per-buffer
  `Task` fan-out, no actor hop (a small boxed producer state keeps sequence
  bookkeeping real-time safe).
- `DictationController` — one delivery task per session drains `channel.chunks`,
  converts via `SessionAudioConverter` (16 kHz mono float) and appends to the
  engine in exact producer order. After `stop()` the delivery task is awaited
  before finalize. Any degraded channel/sequencer maps to
  `.captureFailed` terminal — never an ordinary success outcome.

## Deterministic evidence (Tests/ZephyrFlowCoreTests/main.swift JOE-2247 block)

| Check | Expected | Result |
|---|---|---|
| Memory bounded under saturation (1000 enqueues, cap 64, no consumer) | 64 accepted, 936 overflow counted | pass |
| Overflow NOT silent | stats.overflowDropped == 936 | pass |
| Cross-session chunk rejected | wrongSessionRejected == 1, degraded | pass |
| Post-close chunk counted | closedDropped == 1 | pass |
| Exact order accepted on sequencer | c0,c1 accepted | pass |
| Gap fast-forward counted once | gaps==1, nextExpected advances | pass |
| Reordered counted, refused | reordered==1 | pass |

## Benchmarks / notes

- Real-time producer path = 1 deep copy + 1 bounded ring push + 1 countable
  stats write; no allocation after the copy, no engine/inference stall on the
  audio thread. (Deterministic microbenchmarks without a microphone belong to
  JOE-2292; real-device latency evidence is JOE-2257.)

## Verification

`swift run ZephyrFlowCoreTests` exit 0 · `swift build` exit 0 · `mkdocs build
--strict` exit 0.
