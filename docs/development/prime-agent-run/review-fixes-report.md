# Review-Fixes Candidate Report — branch agent/zephyr-review-fixes @ ef59e81

**Status:** remediation candidate (NOT re-approved). Three review rounds were
addressed; a fourth review is required before merge. This file is regenerated
from the candidate head ef59e81.

## History
- `0e5f0b2` (original): review 1 → BLOCKED (15 blockers).
- `0adb5f1` (round 1 fixes): review 2 → STILL BLOCKED (9 blockers + REQ + nits).
- `85fe010` (round 2 fixes): review 3 → STILL BLOCKED (9 blockers + REQ + nits).
- `ef59e81` (round 3 fixes): this head. See below.

## What changed vs the original reviewed head
- **48 commits**, 51 files changed, 2795 insertions(+), 370 deletions(-)
- **1108 test checks pass, 0 failures** (CLT suite).
- **All 9 CI gates pass** (including fail-closed strict-concurrency with the
  grouped pipeline, recursive shellcheck, required PyYAML, drift clean,
  coverage >=70, ASan + explicit rapid-control/crash lane).

## Round-3 blockers addressed (review 3 → this head)
| Blocker | Fix | Commit |
|---|---|---|
| B1 drain final-seq race + accepted-sample reconciliation | close-first atomic stop; barrier tracks highest-delivered-while-idle; accepted-sample reconcile; flush only when delivery done | `be1fa50` |
| B2 release during preload still queued; cancel not propagated | pendingBeginTask kept through preload; final cancel checks before history/success | `94f5d95` |
| B3 stage ordering + authoritative finish + terminal telemetry | drainFinished→finalize→transcriptionFinished; transformationFinished after Flow; no terminal-before-review; finish() no force-apply; TerminalGuard emits terminal event | `f1d9c03` |
| B4 exact target lease | windowID + resolution-token enforcement; nil-bundle fail-closed; paste revalidates at event time; no auto-clipboard on failed targets | `ef59e81` |
| B5 Flow returns unsafe text | rejected outcome returns ORIGINAL input; session enters review (no auto-insert) | `ae28262` |
| B6 quarantine not reached | isReady = _isReady && !quarantined; replacement verifies readiness + records digest | `d819eef` |
| B8 history init | isInitialized on fresh install; persist checks init; historyReady only on success; legacy re-encrypted; transactional add/clear/delete; lastWriteError fixed | `4107bca` |
| B9 shell pipeline precedence | grouped grep||true; baseline regenerated | `a4c71b4` |

## Round-3 required-before-merge addressed
- REQ-5 completion identity (no tautological check): `d819eef`
- NITs 1,2,5,6 (local channel clear, allowFallback, find-based recursion,
  missing-binary fail): `d819eef`, `bccea7a`, this head.

## STILL NOT addressed (external / requires CI + hardware + human)
- **REQ-2**: Swift 6 language mode (package is tools 5.10; ~80 baseline
  warnings — documented follow-up).
- **REQ-3 remainder**: a real GitHub Actions run at the exact candidate SHA
  (workflow ready + Actions pinned; requires a runner + push/PR).
- **REQ-1 remainder**: controller-level XCTest (app target bound; CLT
  production-wiring tests added).
- **Human/external gates**: real-device qualification, credentials, JOE-2314
  decision, etc. (runbooks in human-gates.md).
- **B8-remaining (review-3)**: cryptographic binding of WhisperKit to the
  verified bytes (API limitation, documented; digest recorded, not proof of
  loaded bytes).

## Verification
```bash
git fetch origin && git checkout agent/zephyr-review-fixes
bash Scripts/ci_checks.sh      # 9 gates
swift run ZephyrFlowCoreTests  # 1108 checks
git diff --check 0e5f0b2..HEAD
```
