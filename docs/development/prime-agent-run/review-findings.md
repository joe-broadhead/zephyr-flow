# Independent Code Review — BLOCKED (branch 0e5f0b2)

**Date:** 2026-08-09
**Branch reviewed:** `agent/zephyr-production-run-20260808T103416Z` @ `0e5f0b2`
**Reviewer:** independent (external environment; static review + GitHub tree; could not execute the macOS app/XCTest locally)

## Verdict

**BLOCKED — do not merge.** The terminal tree at `0e5f0b2` does not satisfy the central production
invariants. Useful scaffolding and typed domain vocabulary, but production orchestration contradicts
multiple acceptance criteria.

## Reviewer's headline findings (confirmed against source)

| Area | Finding |
|---|---|
| Audio losslessness | **Fail** — bounded channel never dequeues/releases capacity (permanent overflow after `capacity` chunks) |
| Audio format | Channel-0 mono mislabeled as multichannel; fixed 16k/16k reconcile ignores real source rate |
| Drain barrier | Racy; `await deliveryTask.value` unbounded despite 3s barrier deadline |
| Control plane | Release/cancel queue behind model preload; state machine transitions discarded (`_ =`); `finishTerminal(category:)` ignores `category` |
| Session lifecycle | Completed session never cleared → blocks all subsequent sessions |
| Target insertion | validate/insert TOCTOU gap; AX timeout does not prevent a stale write |
| Sensitivity | Pure policy good; production integration fails — 3 automatic paths return `.explicitlyCopiedByUser` (incl. secure-field auto-copy) |
| Apple Speech | Errored partial promoted to `.complete`; finalization can hang |
| WhisperKit | Silent 60s audio truncation; decode ownership unsafe under stuck native call; language not wired |
| History | Two incompatible stores on same `history.json`; production encryption not configured |
| Flow | Per-line placeholder zero-restart → wrong protected-span restore across lines |
| Model acquisition | Verified artifact not bound to loaded model; preload before explicit consent |
| CI/gate | `swift build | grep || true` swallows failures; 4 referenced qual scripts missing; mutable Actions refs; terminal SHA `0e5f0b2` not the validated head |
| Done honesty | JOE-2243 marked done while its own evidence lists unfinished singleton migration |

## CONFIRMED-GOOD (preserve)

Branch isolation (no master/tag changes); external human gates not falsely marked Done; typed domain
vocabulary; conservative pure sensitivity policy; pasteboard state-machine design; privacy-oriented
observability; Aurum scope discipline; evidence organization.

## Remediation order (from reviewer, adopted)

1. Reopen affected Linear issues and withdraw production-complete/final-gate claim.
2. Repair session lifecycle + audio first (queue consumption, format metadata, source-rate accounting,
   drain acknowledgement, direct cancellation, legal state transitions, terminal emission, controller cleanup).
3. Repair target + sensitivity boundaries (one validation/write transaction, enforceable AX timeout,
   remove automatic secure/fallback clipboard writes).
4. Repair engine completeness (Apple finalization; WhisperKit long-input/ownership/language).
5. Unify + correctly initialize history storage and encryption.
6. Repair Flow protected spans and fail-closed guard outcomes.
7. Bind model verification + explicit consent to the exact loaded artifact.
8. Replace model-only evidence with production-wiring integration tests.
9. Repair CI, pin Actions, run the exact corrected terminal SHA on macOS/Xcode.
10. Create a new candidate ledger and request a fresh review.

## Status of remediation

- Linear: 24 issues reopened to In Progress (2026-08-09). Review comments pending Linear re-auth.
- This branch is experimental; a reworked production candidate must be re-reviewed at its own SHA.
