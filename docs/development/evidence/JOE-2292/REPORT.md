# JOE-2292 — deterministic test laboratory (randomized session stress)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SessionStressHarness.swift`, AppKit-free)

- `SplitMix64`: seeded deterministic PRNG (reproducible sequences).
- `StressSessionProvider`: a `DictationSessionStageProviding` driven by the
  seeded PRNG — random partial counts, completeness (complete/partial/
  truncated), validation outcomes (validated/targetChanged/targetUnknown/
  secureTarget/deadlineExceeded), insertion outcomes (verified/unverified/
  targetChanged), randomized delays (exercises cancellation windows),
  normal/secure sensitivity per iteration.
- `SessionStressHarness.run(config:)`: drives N seeded sessions through the
  actor with randomized control timing (end/cancel/discard) and asserts:
  exactly-one terminal outcome (second end is a no-op with no extra side
  effects), no cross-session attribution (parallel sessions with disjoint
  provider counters), no forbidden sensitive side effects (secure sessions
  never insert/history), target validation before mutation (insertCount <=
  validateCount), resource release. Failing seeds replay locally + CI.
- Session actor fix surfaced by the laboratory: review phases now consume
  the SAME command stream as the capture wait (a buffered follow-up is never
  lost when a review phase replaces the capture wait) — the earlier design
  recreated the stream and deadlocked when a review phase appeared.

## Test programme (11 JOE-2292 checks)

PRNG determinism (two seeded generators produce identical sequences);
stress run green at fixed seeds (40 and 60 iterations) — exactly-one
terminal, cross-session ok, sensitive side effects blocked, validation
before mutation, zero violations; replay reproducibility (same seed -> same
report); secure snapshot carries secure sensitivity; corpus of seeds all
green. Coverage of the terminal taxonomy is exercised across the seeded
corpus.

## Acceptance criteria

- Complete session pipeline runs without AppKit/AVFoundation/Speech/models/
  files/real time — StressSessionProvider + harness (real `Task.sleep` is
  bounded and tiny; core sequencing is deterministic).
- Randomized tests exercise state transitions and terminal categories —
  seeded outcomes cover validated/change/unknown/secure/deadline + cancel.
- Discovered defects add stable regression seeds — the review-phase
  deadlock was found by the harness and fixed; seed corpus retained.
- Failure output bounded + payload-safe — reports carry counts + violation
  strings (no transcript bodies).
- Deterministic under parallel CI — seeded PRNG, no wall-clock dependence.

## Evidence

- Coverage map: `docs/development/ci/coverage-map.md` links invariants/
  transitions to test blocks (JOE-2240..2292).
- Seed corpus + baseline: fixed seeds 0x5EED/0xBEEF/0x1111/0x2222/0x3333;
  full suite green; baseline duration ~8s (compiled).
