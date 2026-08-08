# JOE-2279 — typed FlowOutcome (changes, loss class, warnings, fallback)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`FlowContract.swift` + actors)

- `FlowRequest`: sessionID, text, style, language, sensitivity, hard deadline.
- `FlowOutcome`: output text, requestedStyle, resolvedLossClass, backend,
  capabilityID/version, language, changedRangeCount (counts only),
  protectedSpanCount, protectedSpansPreserved, status (accepted/rejected/
  deadlineExceeded/cancelled/superseded), controlled warnings, fallbackReason,
  durationNanos, termination.
- `FlowOutcomeDiagnostics`: content-redacted view (no text/ranges exposing
  content).
- `FlowProcessor.process(request)` — deterministic rules outcome.
- `FlowRouter.process(request)` — sensitivity/capability policy rejects
  BEFORE execution (secure + semantic => conservative with
  secureSensitivityConservative warning); enhanced deadline via withTaskGroup
  — a late result is dropped and can never overwrite the fallback; fallback
  is an explicit `.deadlineExceeded`/`.rejected` outcome, never
  indistinguishable from success.
- `EnhancedFlowProcessor.process(request)` — guardrail rejection returns
  `.rejected` with reason + conservative fallback visible to UI/metrics.
- Production orchestration (DictationController) migrated from
  `process(...) -> String` to the typed outcome API (logs status/lossClass/
  protected flag/fallback — no content).

## Acceptance criteria

- Every style/backend path returns a complete typed outcome — tests.
- Sensitivity and capability policy can reject a backend before execution —
  secure+semantic → conservative (test).
- Guard rejection/fallback visible to UI/metrics without payload — status +
  fallbackReason (test).
- Safe fallback is an explicit outcome — .rejected/.deadlineExceeded cases.
- Flow APIs receive SessionID/sensitivity/cancellation context — FlowRequest.
- Deadline cannot block indefinitely nor let a late result overwrite the
  fallback — withTaskGroup + lateResultIgnored.
- Diagnostic serialization redacts text — diagnostics view (test).
- Legacy `process -> String` removed from production orchestration —
  controller uses outcome API.

## Deterministic tests (JOE-2279 block)

Clean outcome complete with loss class/backend/capability; professional
semantic class; diagnostics redact content; secure+semantic → conservative
with warning; guardrail rejection visible with fallback. All pass.

## Remaining manual validation (human gate)

Real-device Flow UI/metrics review across styles (outcome cards) — runbook
retained.
