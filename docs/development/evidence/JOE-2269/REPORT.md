# JOE-2269 — typed InsertionOutcome; remove false verified success

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## What changed

`InsertionResult` (ambiguous `.inserted` / `.pasted` / `.copiedToClipboard`
treated as verified success) is removed and replaced by the typed, controlled
`InsertionOutcome` in `Sources/ZephyrFlowCore/Models.swift`.

### Outcomes (all insertion paths return exactly one)

- `verifiedInserted(strategy, evidence, warnings)` — only when post-write
  evidence confirms the write (in-memory re-read compare; content never
  logged).
- `eventPostedUnverified(strategy, warnings)` — Cmd-V/terminal paste posted
  but target never confirmed receipt. **Never described as inserted.**
- `explicitlyCopiedByUser` — review-panel/copy-only explicit copy.
- `targetChanged`, `targetGone`, `targetUnknown`, `secureTarget`,
  `notEditable` — no-side-effect uncertainty states (JOE-2268 mapping).
- `clipboardNotRestoredBecauseChanged`, `clipboardRestoreFailed` — clipboard
  hygiene failures.
- `deadlineExceeded`, `cancelled`, `failed(String)` (typed failure).

### Central policy (exhaustive switches; adding a case is a compile error)

`permitsGreenSuccessUI`, `permitsHistoryRetention`,
`permitsAutomaticPanelDismissal`, `permitsReliabilityMetrics`, `isUncertain`,
`userFacingMessage` (user-visible language distinguishing verified insertion,
unverified posting, explicit copy and no-side-effect states).

### Strategy + evidence mapping

- `.axSelectedText` / `.axValue` success + post-write re-read match →
  `verifiedInserted(evidence: .postWriteSelectionReRead)`.
- `.axSelectedText` / `.axValue` set succeeded but re-read mismatch →
  `eventPostedUnverified(.noPostWriteVerification)`.
- `.clipboardPaste` / `.terminalPaste` posted → `eventPostedUnverified`; if
  clipboard changed meanwhile → `clipboardNotRestoredBecauseChanged`; if
  restore failed → `clipboardRestoreFailed`.
- `.copyOnly` / secure-field copy / fallback → `explicitlyCopiedByUser`.

### Central consumption

- DictationController history write gate: `result.permitsHistoryRetention`
  AND sensitivity policy (secure/unknown never history).
- Panel UI/status text: driven by `userFacingMessage`; green success only
  when `permitsGreenSuccessUI`.
- Control-plane terminal stages: `.insertionSucceeded` only for
  verified/explicit-copy/unverified-posted; everything else `.insertionFailed`.

## Acceptance criteria

- Every insertion path returns one typed outcome — service + controller map
  all paths (strategy loop is exhaustive).
- User-visible language distinguishes verified / unverified / copy /
  no-side-effect — `userFacingMessage` table + tests.
- History/metrics policy consumes the outcome centrally — controller gate +
  `permitsReliabilityMetrics` (all outcomes metricable, content-free).
- Unknown/default cases are non-success and fail closed —
  `isUncertain`/`permitsGreenSuccessUI` false for all uncertainty states.
- Exhaustive tests fail when a new outcome lacks UI/privacy/metrics policy —
  golden-mapping tests + all-case policy sanity loop; exhaustive switches
  enforce compile-time policy.

## Deterministic tests (Tests/ZephyrFlowCoreTests/main.swift, JOE-2269 block)

Golden mappings for every outcome (verified green/history, unverified not
green/not history/distinct message, copied green+history, uncertain states
no green/no history/no auto-dismiss, clipboard hygiene, deadline/cancelled/
failed non-success, all metrics-permitted, strategy retention) + policy
defined for every outcome case. All pass; `swift build` 0; `mkdocs --strict` 0.
