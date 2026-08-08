# JOE-2252 — rich EngineResult completeness, provenance and warnings

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/Models.swift`)

- `EngineResultCompleteness`: complete / partial / truncated / degraded;
  `permitsSuccessClaim` only for `.complete` (unknown/default conservative).
- `EngineResultTermination`: completed / cancelled / deadlineExceeded / failed.
- `EngineWarning`: partialFallback, shortAudioFallback, deadlineExceeded,
  truncation, captureDegraded, lowConfidence, engineFallback.
- `EngineFrameAccounting` (JOE-2248 counts): captured/delivered/decoded/
  dropped; `reconciled(ratio:tolerance:)` — complete results REQUIRE
  reconciled frame evidence (missing/zero evidence cannot enable success).
- `EngineResult`: text (NO redundant processedText — Flow is a separate
  stage), completeness, frameAccounting, EngineIdentity (kind/model/version/
  digest), language requested/detected, confidence + source, timing
  provenance (started/ended uptime nanos, inference duration), warnings,
  fallbackReason, termination.
- `isComplete`: completeness == .complete AND reconciled frame evidence.
- `diagnosticsPayload`: content-free view (no transcript text).
- `typealias FinalTranscription = EngineResult` — explicit backward-compat
  migration; callers updated.

## Engines

- WhisperKit: short-audio fallback → `.partial` + shortAudioFallback warning;
  final-decode failure with rolling partial → `.partial` + partialFallback
  (NEVER complete); success → `.complete` with reconciled frame accounting
  (captured==delivered==decoded at 16 kHz reference).
- Apple Speech: sawFinal && no error → `.complete`; rolling partial →
  `.partial`; otherwise `.degraded`; warnings/fallbackReason set accordingly.
- Both produce the same semantic `EngineResult` contract (protocol return type).

## Acceptance criteria

- WhisperKit and Apple Speech produce the same semantic contract — both
  return EngineResult with completeness/accounting/identity/warnings.
- Complete requires reconciled frame/range evidence — `isComplete` gate +
  tests.
- Partial fallback, short-audio fallback, deadline, truncation
  distinguishable — completeness + warnings + termination + tests.
- Unknown/default conservative — no success claim without evidence.
- Diagnostics exclude transcript content by default — diagnosticsPayload.

## Deterministic tests (JOE-2252 block)

Complete with reconciled evidence; complete without evidence not trusted;
unreconciled evidence fails; partial/truncated/degraded conservative;
partial/short-audio/deadline distinguishable; diagnostics exclude text;
no redundant processedText. All pass.

## Remaining manual validation (human gate)

Golden result fixtures across real engines + exhaustive UI/history/metrics
mapping for each completeness case (deterministic policy covered; real-device
fixture runbook retained).
