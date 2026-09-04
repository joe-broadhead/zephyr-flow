# Sensitivity policy table (JOE-2258)

One authoritative mapping, enforced by `SensitivityPolicy.allowance(...)` in
`Sources/ZephyrFlowCore/SensitivityPolicy.swift`. The code is the source of
truth; this table documents it. `secure` and `unknown` fail closed.

| Surface                | normal | secure | unknown |
|------------------------|--------|--------|---------|
| audioRetention         | allowed | allowed (transient PCM; persistence gated separately) | allowed (transient PCM only) |
| flowModes              | all     | verbatim/conservative only (no automatic side effects) | verbatim only |
| automaticInsertion     | allowed | blocked (explicit user action required) | blocked (fail closed) |
| clipboardFallback      | allowed | blocked | blocked |
| history                | allowed | blocked | blocked |
| logs                   | lifecycle only (no payloads ever) | payload diagnostics blocked | payload diagnostics blocked |
| metrics                | allowed | allowed (anonymous, content-free) | allowed (anonymous, content-free) |
| uiPreview              | allowed | blocked | blocked |
| supportBundle          | allowed | blocked | blocked |

## Re-evaluation before insertion

`SessionSensitivityDecision.resolve(sessionStart:preInsertion:)` keeps the most
restrictive of the two captures: any `secure` at either point yields `secure`,
any `unknown` at either point yields `unknown`, and a missing pre-insertion
assessment fails closed to `unknown` (never silently downgrades to normal even
when AX permission is absent or a role lookup failed).

## Explicit user copy action

`TranscriptStageGate.explicitCopyAllowed(...)` permits a separate, informed
copy action for any class. The audit record
(`ExplicitCopyAuditRecord`) contains sensitivity class, whether the session
was upgraded before insertion, and a timestamp — never transcript content.

## Consumption

Every transcript-bearing stage routes through `TranscriptStageGate.gate(...)`
before performing its action; UI/services do not re-implement the table.


## Pasteboard transaction gate (JOE-2260)

Automatic paste runs only as a lossless bounded transaction:
`PasteboardTransaction` snapshots every item/type/data (never flattened),
enforces a reviewed budget before any mutation, uses a unique marker +
change-count equivalence for safe restoration, and preserves user/target
changes (`notRestoredBecauseChanged`). Only `.normal` sensitivity may call it.
