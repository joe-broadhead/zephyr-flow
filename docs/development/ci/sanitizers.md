# Sanitizer lanes and honest exclusions (JOE-2293)

## Configured lanes (require a successful candidate run)

- **Address Sanitizer** (`swift test --sanitize=address`): XCTest target.
  Checks memory safety in the exercised paths. An ASan pass is not a general
  leak-free claim, and it does not run every test in the separate Core runner.
  XCTest covers Core contracts plus bounded in-memory PCM and injected
  settings/permission adapter checks. It does not qualify real microphone or
  full native-session ownership. Retain candidate results before claiming a pass.
- **Rapid-control stress** (seeded, in the Core suite): randomized
  press/release/cancel sequences assert exactly-one terminal, idempotent
  duplicate edges and cancel-termination (JOE-2246 invariants).
- **Crash/relaunch recovery** (deterministic, in the Core suite): versioned
  fault points (settings/history/model-promote/pasteboard) with atomic-vs-
  partial write simulation; recovery must yield OLD or NEW consistent state,
  never MIXED. A real app kill/relaunch campaign on the exact candidate remains
  implementation and qualification work, not evidence supplied by these simulations.
- **Strict-concurrency compile-time checks**: gate 3 builds app and test
  targets with `-strict-concurrency=complete` and fails on new/increased
  warnings against the reviewed baseline. These are not runtime race checks.

## Documented exclusions (honest)

- **Thread Sanitizer**: not configured in this runner. No candidate-specific
  TSan support assessment or runtime race result is established here. Strict
  concurrency and seeded stress provide different, partial evidence; they
  are not equivalent substitutes. Qualification needs an explicit supported
  toolchain assessment and any justified exclusions.
- **Real microphone/transcript paths**: sanitizer lanes use synthetic fixtures
  and in-memory adapters; no private transcripts or credentials are required.

## Pinning + artifacts

- Toolchain: Xcode **16.4 / 16F6** is selected and verified; actual Swift and
  formatter versions and source SHA are recorded. The `macos-15` runner image
  is not immutable, and other tool/dependency pins remain incomplete.
  Full ASan/stress logs and command exit codes are uploaded on successful and
  failed runs when the runner reaches the upload step. See [CI policy](ci-policy.md).
- CI time caps never convert a timeout into success: lanes exit non-zero on
  timeout.

## Validation scope

- Gate regression tests inject synthetic command failures, missing profiles
  and missing control/recovery markers into tool doubles. These validate
  shell orchestration and error propagation, not the sanitizer itself.
- ASan failure-detection evidence must come from an actual supported Xcode
  run; inspection or simulated exit codes cannot establish that result.
- Crash recovery: the Core tests inject partial-write + non-atomic-commit
  fixtures and assert recovery rolls back to OLD (never mixed).
- Rapid control: duplicate release edges and cancel-after-terminal are
  asserted as no-ops.


## Swift 6 language mode (REQ-2 follow-up)

The package is `swift-tools-version: 5.10` and the strict-concurrency gate runs
`-strict-concurrency=complete` in Swift 5 mode. The warning baseline contains
diagnostics the compiler describes as errors in Swift 6 language mode
(non-Sendable AX/AVFoundation captures, lock use from async contexts, etc.).
Closing the Swift 6 language-mode gap is a follow-up that requires resolving
those baseline warnings (or explicitly quarantining them) and is NOT claimed
done here. The gate is honest about this: it is labeled 'Swift 5 mode'.
