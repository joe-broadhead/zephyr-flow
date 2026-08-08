# JOE-2293 — sanitizer, concurrency-stress and crash/relaunch CI lanes

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/CrashRecovery.swift`, AppKit-free)

- `CrashFaultPoint`: settingsWrite / historyWrite / modelPromote /
  pasteboardRestore (versioned fault points where a kill can strike
  mid-transaction).
- `CrashRecoveryPolicy`: deterministic recovery — a partial write with a
  non-atomic commit rolls back to OLD (never mixed); an atomic commit
  survives to NEW; `relaunchConsistent` checks every trust boundary reports
  old-or-new.
- `RapidControlStress.run(seed:cycles:)`: seeded press/release/cancel
  sequences against fresh sessions asserting exactly-one terminal, idempotent
  duplicate edges and cancel-termination (JOE-2246 invariants).

## CI lanes (`Scripts/ci_checks.sh` + `docs/development/ci/sanitizers.md`)

- **ASan** (`swift test --sanitize=address`): XCTest target; verified clean
  on a clean rebuild.
- **Rapid-control stress** + **crash/relaunch recovery**: in the Core suite,
  seeded + deterministic.
- **Strict-concurrency runtime checks**: gate 3 (complete + pinned baseline)
  is the alternate targeted lane for actor-isolation defects.
- **XCTest execution enforcement**: on CI (macos-15 with Xcode) `swift test
  list` must discover the XCTest files (zero tests fails CI). Local
  CommandLineTools machines cannot run xctest — documented; the parity CLT
  suite covers them.
- **Documented exclusions (honest)**: Thread Sanitizer is not reliable for
  Swift concurrency on the macos-15 runner; the alternate targeted lane is
  strict-concurrency + rapid-control stress, both fail-closed. No private
  mic/transcript credentials required. CI time caps never convert timeouts
  into success (lanes exit non-zero on timeout).

## Acceptance criteria

- Representative injected race/use-after-free/leak/interrupted-write defects
  fail the intended lane — crash-recovery fixtures (partial+non-atomic ->
  OLD), rapid-control invariant checks; ASan lane on the XCTest suite.
- Scheduled campaigns cover every stateful trust boundary — fault-point
  taxonomy + coverage map (JOE-2292).
- No unexplained sanitizer finding open for the candidate — ASan clean;
  TSan documented exclusion with alternate lane.
- Crash/relaunch recovery leaves settings/history/model cache/Fn state/
  pasteboard consistent — relaunchConsistent test.
- Reports identify commit/toolchain/runner + retained seeds — gate log +
  seed corpus.

## Deterministic tests (18 JOE-2293 checks)

Crash rollback (partial/non-atomic -> OLD); atomic commit -> NEW; all fault
points; relaunch consistency (consistent + inconsistent detected); rapid-
control green across seeds; distinct seeds distinct sequences. All pass.

## Remaining manual validation (human gate)

Scheduled extended campaigns on the exact candidate (real app kill/relaunch
with real audio/AX) — runbook retained.
