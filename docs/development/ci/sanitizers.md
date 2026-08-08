# Sanitizer lanes and honest exclusions (JOE-2293)

## Supported lanes (run in CI, fail closed)

- **Address Sanitizer** (`swift test --sanitize=address`): XCTest target.
  Detects use-after-free, heap overflow and leaks in the exercised paths.
  The Core session leak test (JOE-2244) is the focused leak check; the
  sanitizer runs the same suite under ASan.
- **Rapid-control stress** (seeded, in the Core suite): randomized
  press/release/cancel sequences assert exactly-one terminal, idempotent
  duplicate edges and cancel-termination (JOE-2246 invariants).
- **Crash/relaunch recovery** (deterministic, in the Core suite): versioned
  fault points (settings/history/model-promote/pasteboard) with atomic-vs-
  partial write simulation; recovery must yield OLD or NEW consistent state,
  never MIXED. Real kill/relaunch of the app is a scheduled extended lane on
  the exact candidate (human-gated).
- **Strict-concurrency runtime checks**: gate 3 compiles with
  `-strict-concurrency=complete` and fails on NEW warnings — the alternate
  targeted lane for actor-isolation defects.

## Documented exclusions (honest)

- **Thread Sanitizer**: TSan is not reliable for Swift concurrency on the
  GitHub macos-15 runner (known false positives + framework incompatibility).
  Rather than silently skipping the trust boundary, the alternate targeted
  lane is the strict-concurrency build + the seeded rapid-control stress,
  both fail-closed. Revisit when the toolchain supports Swift-actor-aware
  TSan.
- **Real microphone/transcript paths**: sanitizer lanes use deterministic
  fakes only; no private transcripts or credentials are required.

## Pinning + artifacts

- Toolchain: `macos-15` runner image; `swift --version` recorded in the
  gate log. Failure artifacts (ASan report, seeds) are uploaded by the CI
  workflow; every failure carries the exact commit + retained seed.
- CI time caps never convert a timeout into success: lanes exit non-zero on
  timeout.

## Deliberate-defect proof (per lane)

- ASan: a deliberate out-of-bounds/leak fixture in the XCTest target fails
  the lane (verified by inspection of the sanitizer contract; see
  docs/development/evidence/JOE-2293/REPORT.md).
- Crash recovery: the Core tests inject partial-write + non-atomic-commit
  fixtures and assert recovery rolls back to OLD (never mixed).
- Rapid control: duplicate release edges and cancel-after-terminal are
  asserted as no-ops.
