# Review-Fixes Candidate Report — branch agent/zephyr-review-fixes @ 9056558

**Status:** remediation candidate (NOT yet re-approved). Two independent reviews
were addressed; a third review is required before merge.

## History
- `0e5f0b2` (production-run head): first review → **BLOCKED** (15 blockers).
- `0adb5f1` (round-1 fixes): second review → **STILL BLOCKED** (9 blockers +
  required-before-merge + nits).
- `9056558` (current): rounds 1-3 fixes applied. See below.

## What changed since the reviewed head (`0e5f0b2`)
- **34 commits**, 48 files changed, 2085 insertions(+), 331 deletions(-)
- **1091 test checks pass, 0 failures** on the CLT suite (Core + stress).
- **All 9 CI gates pass** on this branch (XCTest/CLT parity, strict-concurrency
  (Swift 5 mode) vs pinned baseline, swift-format, shell+YAML, docs, drift,
  coverage line>=70, sanitizer/ASan).

## BLOCKERS addressed (rounds 1-3)
| # | Blocker | Commit(s) |
|---|---|---|
| 1 | Audio channel never dequeues | R1.1 `28d1061` |
| 2 | Audio format/reconcile | R1.2 `1cd86cd` |
| 3 | Drain race + unbounded wait | R1.3 `b7ba09d` + R1.3v2 `9564221` |
| 4 | Release/cancel behind preload | R1.4 `3e53fb1` + R2/4 `8e0a95c` |
| 5 | State machine not wired / terminal-after-review | R1.5 `837d5c9` + R2/3 `710cf09` |
| 6 | Session never cleared | R1.6 `ce59613` |
| 7 | Validate/insert TOCTOU | R2.1 `5e04f50` (bundle re-check + pre-paste secure check) |
| 8 | AX timeout unsafe | R2.2 `0650a51` + R2/5 `dcbfe3b` (writeMayHaveApplied) |
| 9 | Auto clipboard → explicit | R9 `d2eb97b` + R2/5 |
| 10 | Apple Speech partial→complete | R3.1 `5d7d512` |
| 11 | Whisper truncation/ownership/language | R3.2 `37b08e5` |
| 12 | Dual history stores | R4.1 `2e6fe77` |
| 13 | Flow span collision | R5.1 `d5e5fd5` |
| 14 | Model preload before consent | R6.1 `b87719e` |
| 15 | CI gate fail-closed | R8.x `51416c1` + `ebdfc8f` |
| + | Engine cleanup / bounded cancel / quarantine | R6 `25138b1` |
| + | Fail-closed encrypted history init | R7 `ba428cf` |
| + | Flow never fails open + real sensitivity | R2/9 `74d4cd7` |
| + | Durable control mailbox + cancel at every stage | R2/4 `8e0a95c` |

## Required-before-merge addressed
- REQ-4 truthful terminal UI + lastSessionID race: `a619025`
- REQ-5 saveHistory migration privacy-safe: `6843e51`
- REQ-6 converter EOS tail flush: `942ecb8`
- REQ-2 honest strict-concurrency labeling (Swift 5 mode): `9056558`
- NITs (occupancy naming, comments, unused param, gate zero-warning): `bccea7a`

## NOT yet addressed (requires CI/hardware/human)
- **B4**: a true one-use target lease passed into insertion (current: bundle
  + secure re-check + pre-insert cancel; element identity is re-resolved, not
  leased).
- **B8**: loading WhisperKit from the exact promoted verified directory (engine
  loads by identifier with downloads disabled; EngineIdentity does not yet carry
  the verified digest).
- **REQ-1**: production-wiring XCTest (controller-level integration tests; the
  CLT suite tests Core). 
- **REQ-3**: full CI lanes (rapid-control + crash/relaunch lanes run only ASan
  locally; no GitHub Actions run at this exact SHA).
- **REQ-7 (partial)**: human/external gates remain (real-device, credentials,
  JOE-2314 decision, etc.) — runbooks in human-gates.md.

## Honest disposition
- The 24 implementation issues reopened in Linear are In Progress with review
  comments; fix evidence is committed on this branch per issue (R-fix commits).
- The original 47 done-with-evidence claims on the production-run branch were
  withdrawn; this branch is the remediation candidate, not a completion claim.
- Human/external gates are NOT claimed done (unchanged).

## Verification
```bash
git fetch origin && git checkout agent/zephyr-review-fixes
bash Scripts/ci_checks.sh      # 9 gates
swift run ZephyrFlowCoreTests  # 1091 checks
git diff --check 0e5f0b2..HEAD
```
