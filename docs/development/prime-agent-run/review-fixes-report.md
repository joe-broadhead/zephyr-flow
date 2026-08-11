# Review-Fixes Candidate Report — branch agent/zephyr-review-fixes @ c0e7480

**Status:** remediation candidate (NOT re-approved). Six review rounds were
addressed; a seventh review is required before merge. This file is regenerated
from the candidate head c0e7480 (pushed, clean).

## History
- `0e5f0b2` (original): review 1 → BLOCKED (15 blockers).
- `0adb5f1` (round 1 fixes): review 2 → STILL BLOCKED (9 blockers + REQ + nits).
- `85fe010` (round 2 fixes): review 3 → STILL BLOCKED (9 blockers + REQ + nits).
- `8a521ac` (round 3 fixes): review 4 → STILL BLOCKED (6 blockers + REQ + nits).
- `b690eed` (round 4 fixes): review 5 → STILL BLOCKED (5 blockers + REQ + nits).
- `ef4e742` (round 5 fixes): review 6 → STILL BLOCKED (4 blockers + REQ + nits).
- `c0e7480` (round 6 fixes): this head. See below.

## What changed vs the original reviewed head
- ~72 commits vs the originally-reviewed head `0e5f0b2`.
- **1213 test checks pass, 0 failures** (CLT suite).
- **All 9 CI gates pass**, including: REQ-4 tuple strict-concurrency baseline
  (39 tuples, 0 new), recursive shellcheck with -print0, required PyYAML,
  drift clean, coverage >=70, ASan lane, explicit rapid-control/crash lane.
- The 6,000-line single main() was split into 8 runPartN() functions (same
  file): the frontend previously peaked near the OS memory limit and was
  killed mid-compile; builds now complete in seconds with a bounded peak.

## Round-6 BLOCKER disposition (each with commit + regression test)
| Blocker | Fix | Commit | Test |
|---|---|---|---|
| B1 cancel during history strands session | applied-insertion-wins: post-history cancel records .lateCancelAfterInsertion and finishes .completed (never a second terminal from .completed); finishTerminal mismatch branch NEVER strands — emits actual/fallback category + always releases/finishes broadcaster with a .terminalMismatch marker | `bb51a4e` | B1r6: block recordHistory, cancel during it -> run exits, broadcaster finishes, exactly one terminal (.completed), late-cancel warning, session released, next session completes |
| B2 shutdown join + manual toggle | TerminationHandshake.abandon(reason:); controller RACES sessionTask.value against a bounded deadline (not isCancelled polling); on failure retains quarantined shutdown owner, no sessionFinished/pasteboardResolved/sessionCompleted; release signal fires only after broadcaster finish; toggle preempts existing pending intent | `bb51a4e` | B2r6: abandon refuses further steps; normal session joined after broadcast finish; preempted intent cancelled |
| B3 TargetLease not enforced | nonce + session/sensitivity identity in matches(); TargetLeaseRegistry consumes nonce ONCE before first side-effecting attempt; leaseStillMatches rebuilds a fresh snapshot + full pure matcher; AX path enforces same lease; frontmostWindowID reads AXValue (was String, always nil); capabilities via AXUIElementIsAttributeSettable | `bb51a4e` | B3r6: cross-session/sensitivity rejection; nonce one-use |
| B4 verified model can't verify .mlmodelc / tokenizer network | production sha256Hex+fileSize DIRECTORY-AWARE (recursive sorted rel paths+lengths+bytes); prefill optional; downloader stages complete tokenizer dir; engine passes tokenizerFolder (no Hub fallback); localOnly enforced | `bb51a4e` | B4r6: directory-model ready; inner-file tamper invalidates; optional prefill absent ready; tokenizer dir in manifest |

## Round-6 REQUIRED-BEFORE-MERGE addressed
- **REQ-2** sealedKeyAuthFailed distinct from sealedKeyUnavailable; controller
  blocks history-enabled admission on plaintextMigrationPending.
- **REQ-3** B1 quiescence wait fixed (elapsed-from-start 1s; resample before
  retention decision).
- **REQ-6 (partial)** evidence regenerated from the actual tested SHA below.
- NITs 1-5 addressed (enhanced backend for clean/raw; flush observes
  end-of-stream; PendingSessionIntent doc; verifiedURL legacy note;
  sessionCompleted not a storage-flush marker).

## Round-6 NITs
- NIT 1: EnhancedFlowProcessor reports .regex backend for .clean/.raw.
- NIT 2: flush observes AVAudioConverterOutputStatus.endOfStream.
- NIT 3: PendingSessionIntent doc ("immutable identity + atomic cancellation flag").
- NIT 4: verifiedURL documented legacy; verifiedArtifact is the source of truth.
- NIT 5: sessionCompleted not emitted for shutdown bookkeeping.

## Still external / honest (unchanged)
- **REQ-1**: exact-SHA GitHub Actions run (workflow ready + Actions pinned;
  requires a runner + push/PR). Cannot be executed from this environment.
- **REQ-3**: Swift 6 language mode (package is tools 5.10; 39 tuple baseline;
  the gate is honestly labeled Swift 5 mode).
- Controller-level XCTest execution (XCTest target compiles against the app;
  execution requires the macOS app runtime).
- Cryptographic binding of WhisperKit loaded bytes (loads the verified
  promoted directory with downloads disabled; digest recorded as provenance).
- Human/external gates (real-device, credentials, JOE-2314, etc.).

## CONFIRMED-GOOD across all rounds
Branch isolation; external human gates not falsely marked Done; typed domain
vocabulary; conservative sensitivity policy; pasteboard state-machine design;
privacy-oriented observability; Aurum scope discipline; evidence organization.
