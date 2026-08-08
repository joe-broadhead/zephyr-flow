# JOE-2270 — selection-safe, bounded, verifiable AX writes

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core model (`Sources/ZephyrFlowCore/AxWritePolicy.swift`, AppKit-free)

- `AxElementCapability` — settable/editable/enabled/secure/role/subrole;
  `writable` = settable && editable && enabled && !secure.
- `AxSelection` — UTF-16 code-unit range with bounds validation; malformed or
  out-of-range selections are rejected and can never reach a write.
- `AxWritePolicy.plan(...)` — decides BEFORE any side effect:
  - hard gates: non-settable / read-only / secure / disabled → `.rejected`;
  - preferred: `AXSelectedText` replacement when a valid selection exists;
  - range/value mutation ONLY with an explicit `AxValueAdapterQualification`
    (versioned capability key + exact bundle + roles + macOS min + evidence
    reference); otherwise `.rejected(.wholeValueNotQualified)` — the generic
    whole-value fallback is gone.
- `AxValueAdapterRegistry` — versioned, unit-testable, **empty by default**
  (no app is qualified until evidence-backed records exist in JOE-2271);
  `hasOverlaps` hygiene check.
- `AxErrorOutcome.map(rawValue:)` — controlled mapping of every AX error code
  to ok/failed/notEditable/notSupported/axDisabled/timeout/illegalArgument/
  unknown (content-free).
- `AxBoundedRunner.run(deadlineNanosAhead:startedAtNanos:nowNanos:operation:)`
  — synchronous AX call on a detached thread; awaited up to the deadline; a
  hung target yields `.deadlineExceeded` and late results are dropped, so the
  session/UI can never block indefinitely. Deterministic fast-path when the
  budget is already expired.

## App wiring (`Sources/ZephyrFlow/Services/InsertionService.swift`)

- `insertViaAccessibility` re-resolves capability + selection + current value
  length immediately before the write; consults `AxWritePolicy`; rejects
  secure/read-only/disabled/out-of-range/whole-value-unqualified with NO write.
- The write runs through `AxBoundedRunner` (1.5 s budget): hung target →
  `.deadlineExceeded` outcome (mapped to `InsertionOutcome.deadlineExceeded`).
- Post-write verification: bounded re-read of `AXSelectedText`/value, in-memory
  compare (never logged) → `.verified` / `.unverified`.
- Caret (`AXSelectedTextRange`) is placed only AFTER a verified mutation.
- `AXError` raw values mapped via `AxErrorOutcome.map`.

## Acceptance criteria

- Non-settable/read-only/secure elements receive no write — policy hard gates
  + tests.
- Out-of-range/malformed selection cannot corrupt the field — `AxSelection`
  validation + tests.
- Hung AX target reaches deadline without hanging — bounded runner + tests
  (500 ms blocking op vs 20 ms budget → deadlineExceeded).
- Verified success requires post-write evidence — re-read compare; otherwise
  unverified/failed.
- Generic AXValue rewriting absent outside qualified adapters — registry empty
  by default; `.rejected(.wholeValueNotQualified)` without qualification.

## Deterministic tests (JOE-2270 block)

Fake element matrix (settable/read-only/secure/disabled), preferred selected
text, out-of-range rejection, whole-value denial without adapter, qualified
append range mutation, registry resolution + overlap detection, Unicode/
emoji/combining UTF-16 selection math, AX error mapping table, bounded runner
(fast completes / hung hits deadline / expired budget never runs). All pass.

## Remaining manual validation (human gate)

Real-app qualification tied to adapter capability keys (multi-window/field
and app exit/relaunch) follows in JOE-2271 registry with evidence; manual AX
matrix runbook same as JOE-2268.
