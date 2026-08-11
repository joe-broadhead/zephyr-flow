# Review-Fixes Candidate Report — branch agent/zephyr-review-fixes @ 4832e15

**Status:** remediation candidate (NOT re-approved). Five review rounds were
addressed; a sixth review is required before merge. This file is regenerated
from the candidate head 4832e15 (pushed, clean).

## History
- `0e5f0b2` (original): review 1 → BLOCKED (15 blockers).
- `0adb5f1` (round 1 fixes): review 2 → STILL BLOCKED (9 blockers + REQ + nits).
- `85fe010` (round 2 fixes): review 3 → STILL BLOCKED (9 blockers + REQ + nits).
- `8a521ac` (round 3 fixes): review 4 → STILL BLOCKED (6 blockers + REQ + nits).
- `b690eed` (round 4 fixes): review 5 → STILL BLOCKED (5 blockers + REQ + nits).
- `4832e15` (round 5 fixes): this head. See below.

## What changed vs the original reviewed head
- **~65 commits**, ~65 files changed vs the originally-reviewed head `0e5f0b2`.
- **1182 test checks pass, 0 failures** (CLT suite).
- **All 9 CI gates pass**, including the REQ-4 tuple-format strict-concurrency
  gate (count file | id | message — file identity + occurrence retained),
  recursive shellcheck with -print0, required PyYAML, drift clean, coverage
  >=70, ASan lane, and the explicit rapid-control/crash-recovery lane.

## Round-5 BLOCKER disposition (each with commit + regression test)
| Blocker | Fix | Commit | Test |
|---|---|---|---|
| B1v2 drain success before consumer completion | consumer completion is a MANDATORY success condition (AudioDrainAssessment, pure Core); stopCapture quiesces (bounded 1s) then QUARANTINES the engine + retains deliveryTask/converter ownership when the consumer is stuck | `f5b8509` | B1r5 suite: drained+incomplete degrades; ownership retained; session error (no success/insertion/history) |
| B2v2 press-edge intent + shutdown quiescence | PendingSessionIntent allocated SYNCHRONOUSLY at the press/toggle edge; release/cancel invalidate it immediately (begin aborts before/after every await); DictationSession.awaitTerminalAndReleased() bounded join; controller joins before .sessionFinished | `e0b72ec` | B2r5 suite: intent invalidation/generations; normal release; live-session not released; cancelled releases |
| B3v2 state machine nonterminal vs invented .failed | NEW legal events .drainFailed/.enginePartial/.engineTruncated/.targetResolutionFailed; stage-dependent canonicalEvent(for:from:); finishTerminal REQUIRES terminal+match (else no release, observable .terminalMismatch); one stored telemetry ID; exact metrics categories | `fd4d32d` | B3r5 suite: stage-specific legality; session-level UI+telemetry agreement (degraded->.degraded, truncated->.truncated); single ID |
| B4v2 paste bound to app only | NEW immutable one-use TargetLease (PID+process-start+bundle+window+element+capabilities+deadline); paste validates WHOLE lease before mutation + at event time; TargetValidationService derives window from focused element's kAXWindowAttribute (bounds-matched); axWindowID fails closed without bounds | `1f9849e` | B4r5 suite: lease match/mismatch (window/field/process/bundle/role/capability/expiry); session carries lease |
| B5v2 verified != all loaded bytes | VerifiedModelArtifact (atomic folder+manifestVersion+aggregateDigest); digest-REQUIRED verification (hash failure = FAIL); manifest enumerates ALL WhisperKit components (MelSpectrogram/AudioEncoder/TextDecoder/TextDecoderContextPrefill/tokenizer/config); digest-complete manifest written at promotion; controller+engine never fall back to identifier loading | `567f820` | B5r5 suite: manifest enumeration; atomic artifact; tamper invalidation |

## Round-5 REQUIRED-BEFORE-MERGE addressed
- **REQ-4** tuple-format concurrency baseline: `count file | id | message`
  (file identity + occurrence retained; sort -u no longer hides new-file
  occurrences). Baseline regenerated (43 tuples). `4832e15`
- **REQ-5** explicit history states: HistoryStorageState (readyEncrypted,
  readyPlaintext, plaintextMigrationPending, sealedKeyUnavailable,
  storageReadFailure, corruptQuarantined, historyDisabled); storage READ
  failure is not corruption (no quarantine); controller consults state
  (history-disabled proceeds; non-ready states surface when enabled).
  `567f820`
- **REQ-6** enhanced-Flow rejection provenance: single transformation +
  single guard; outcome preserves actual backend, original rejection, fallback
  backend, requested-vs-delivered loss class. `567f820`
- **REQ-2** production paths under XCTest: ProductionBlockerTests.swift covers
  all five blocker scenarios + history states; runs under
  `swift test --sanitize=address`. `567f820`

## Round-5 nits addressed
- NIT 1-2: removed B5-MARKER + B5-DIAG prints (round-4 commit, verified).
- NIT 3: axWindowID fails closed (nil) when AX bounds cannot be compared.
- NIT 4: finish() doc no longer overclaims exactly-one outcome.
- NIT 5: capture-accounting decoded=0 (delivered input != decoded output).
- NIT 6: removed redundant channelStats reference.
- NIT 7: removed unused EnhancedFlowProcessor t0.
- NIT 8: SessionAudioConverter.flush drains repeatedly (bounded budget).

## STILL NOT addressed (external / requires CI + hardware + human)
- **REQ-1**: exact-SHA GitHub Actions run (workflow ready + Actions pinned;
  requires a runner + push/PR; the agent branch isn't in the workflow push
  branches). Cannot be executed from this environment.
- **REQ-3**: Swift 6 language mode (package is tools 5.10; 43 tuple baseline
  entries; the gate is honestly labeled Swift 5 mode). Separate refactoring
  branch.
- **Controller-level XCTest on the app executable** (XCTest target compiles
  against ZephyrFlow; execution requires the macOS app runtime).
- **Cryptographic binding of WhisperKit loaded bytes** (loads the verified
  promoted directory with downloads disabled; verified digest recorded as
  provenance).
- **Human/external gates** (real-device, credentials, JOE-2314, etc.) —
  honest, in human-gates.md.

## CONFIRMED-GOOD across all rounds
Branch isolation (no master/tag changes); external human gates not falsely
marked Done; typed domain vocabulary; conservative pure sensitivity policy;
pasteboard state-machine design; privacy-oriented observability; Aurum scope
discipline; evidence organization.
