# Review-Fixes Candidate Report — branch agent/zephyr-review-fixes @ b690eed

**Status:** remediation candidate (NOT re-approved). Four review rounds were
addressed; a fifth review is required before merge. This file is regenerated
from the candidate head b690eed (pushed, clean).

## History
- `0e5f0b2` (original): review 1 → BLOCKED (15 blockers).
- `0adb5f1` (round 1 fixes): review 2 → STILL BLOCKED (9 blockers + REQ + nits).
- `85fe010` (round 2 fixes): review 3 → STILL BLOCKED (9 blockers + REQ + nits).
- `8a521ac` (round 3 fixes): review 4 → STILL BLOCKED (6 blockers + REQ + nits).
- `b690eed` (round 4 fixes): this head. See below.

## What changed vs the original reviewed head
- **57 commits**, 60 files changed, ~3200 insertions(+), ~460 deletions(-)
- **1117 test checks pass, 0 failures** (CLT suite).
- **All 9 CI gates pass** (including fail-closed strict-concurrency with the
  grouped pipeline + unique-message baseline, recursive shellcheck with
  -print0, required PyYAML, drift clean, coverage >=70, ASan + explicit
  rapid-control/crash lane).

## Round-4 blockers addressed (review 4 → this head)
| Blocker | Fix | Commit |
|---|---|---|
| B1v2 drain success before consumer completion | converter EOS flush + tail append moved INTO the delivery task's awaited post-loop block (runs before deliveryFinished); stopCapture waits for deliveryFinished bounded by deadline; success requires drained AND consumer completed | `0628e21` |
| B2v2 control events don't preempt lifecycle | begin runs INSIDE sessionChain (serialized); cancelSession preempts pendingBeginTask during preload; run() checks cancellation before prepare + startCapture; cancel() invokes provider.cancel() immediately; post-history cancel check | `76d1b86` |
| B3v2 stage/telemetry disagreement | finishTerminal inspects the ACTUAL control state reached and emits its category (illegal category from current stage → actual terminal emitted; out-of-sync nonterminal → logged + failed); unique per-session telemetry id; controller drains session terminal telemetry into environment.metrics | `078081e` |
| B4v2 automatic copyOnly cascade + pasteboard-before-check + AX false | .copyOnly removed from ALL automatic cascades (adapter registry + alwaysPaste); paste validates target BEFORE clipboard mutation and again at event time; AX revoked fails closed (targetUnknown/failed) at entry + both paste checks | `8759960` |
| B5v2 history migration quarantined | isInitialized set immediately after decode (BEFORE migration persist); migration errors keep decoded doc in memory (retry next launch), only genuine corruption quarantines; production-order regression tests | `76ea38e` |
| B6v2 WhisperKit loads from own cache | WhisperKitEngine.load(model:verifiedFolder:) loads from the app-owned VERIFIED directory via WhisperKit modelFolder: with download:false; controller passes store.verifiedURL(for:).path at all 3 load sites; identifier load only when no verified artifact | `8ef533c` |

## Round-4 nits addressed
- Removed B5-SESSION-DEBUG print (source) + B5-DEBUG test prints.
- FlowProcessor: rejected fallback (returns original input) reports
  changedRangeCount == 0 (was 1 whenever transformed output differed).
- finish() doc contract: callers must match emitted telemetry to the returned
  (authoritative) control state.
- axWindowID: comment overclaim removed — now actually matches CG window
  bounds (same PID + bounds within tolerance), not the first window of the PID.
- Scripts/ci_checks.sh: find -print0 + read -d '' (space/newline-safe) in
  both bash -n and shellcheck loops.
- strict-concurrency gate canonicalizes to UNIQUE MESSAGE only (was mixed
  'File.swift: warning:' + '`- warning:' duplicates); baseline regenerated
  (39 unique messages).
- swift-format: one-variable-per-line in axWindowID bounds matching.

## STILL NOT addressed (external / requires CI + hardware + human)
- **Swift 6 language mode** (package is tools 5.10; ~39 unique baseline
  warnings; the gate is honestly labeled Swift 5 mode). Tracked as a separate
  refactoring merge requirement.
- **Exact-SHA GitHub Actions run** (workflow ready + Actions pinned; requires
  a runner + push/PR; the agent branch isn't in the workflow push branches).
- **Controller-level XCTest** (app-target bound; CLT production-wiring tests
  added — B2v2, B3v2, B4v2 wiring, B5v2, B6v2).
- **Cryptographic binding of WhisperKit to the verified bytes** (WhisperKit
  API loads by identifier/folder with downloads disabled; the verified digest
  is recorded as provenance metadata — the loaded bytes are the promoted
  verified directory, but no post-load byte-for-byte re-hash of the loaded
  in-memory model; documented).
- **Human/external gates** (real-device, credentials, JOE-2314, etc.) —
  honest, in human-gates.md.

## CONFIRMED-GOOD across all rounds
Branch isolation (no master/tag changes); external human gates not falsely
marked Done; typed domain vocabulary; conservative pure sensitivity policy;
pasteboard state-machine design; privacy-oriented observability; Aurum scope
discipline; evidence organization.
