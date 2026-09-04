# Product invariants and terminal outcome taxonomy

**Owners:** Root programme (contract holder), all subsystems.
**Source:** JOE-2240 · milestone M0.
**Status:** Accepted baseline contract; add new invariants only via review.

## 1. Scope

This document is the authoritative definition of what a Zephyr Flow session may
claim and how every operation terminates. It is the shared vocabulary for the
session state machine (ADR 0001), engine results, privacy policy, target
insertion, Flow rules, the UI and release evidence.

## 2. Product invariants

| # | Invariant | Enforcement surface |
|---|-----------|---------------------|
| I1 | Capture order is preserved end-to-end: frames reach the engine in the exact sequence captured, with no silent reordering. | `AudioChunk` sequence + ordered channel (JOE-2247) |
| I2 | Completeness is honest: a final result claims `complete` only when every accepted frame reached the engine and was decoded. | Drain barrier + frame accounting (JOE-2248) |
| I3 | Flow fidelity: every transformation declares its loss class; protected spans survive unchanged or trigger conservative fallback. | `FlowLossClass` + protected-span grammar (JOE-2275) |
| I4 | Target fidelity: automatic insertion happens only into the captured, revalidated target. | `TargetSnapshot` + revalidation (JOE-2267/2268) |
| I5 | Sensitivity confinement: secure and unknown sessions allow no automatic history, clipboard fallback or payload diagnostics. | `SessionSensitivity` policy (JOE-2241/2258/2259) |
| I6 | Artifact authenticity: any claim (inserted, saved, copied, metric) names its controlled outcome; no path conflates compatible results. | Outcome taxonomy below (JOE-2240) |
| I7 | Terminals are absorbing: a session or stage terminates exactly once; duplicate/late completion attempts are rejected and reported. | `SessionTerminalGate`, state machine absorbing terminals (JOE-2240/2242) |
| I8 | Default-safe unknown state: any unrecognised condition fails closed, never into success UI or automatic side effects. | `OutcomePolicy.failClosed`, `SessionSensitivity.unknown` |

## 3. Terminal outcome taxonomy

Exactly one of these describes every terminal state of a session, engine,
Flow or insertion stage (name in code: `StageOutcomeCategory`).

| Outcome | Meaning |
|---------|---------|
| `completed` | Stage finished exactly as requested. |
| `degraded` | Finished with a typed non-fatal degradation. |
| `partial` | Produced a usable but incomplete result. |
| `truncated` | Input exceeded the bounded design; result truncated. |
| `cancelled` | Cancelled by user/control plane. |
| `deadlineExceeded` | Terminated by a deadline; never ordinary success. |
| `targetChanged` | Intended target changed identity/sensitivity. |
| `secureTarget` | Target is secure; stage failed closed. |
| `failed` | Stage failed; no success-shaped result. |
| `abandonedDuringShutdown` | Abandoned during application termination; reported honestly. |

## 4. Outcome policy table

Policy (`OutcomePolicy`) decides which surfaces may consume an outcome.
Unknown/missing policy must fail closed (I8).

| Outcome | Success UI | History | Clipboard | Metrics | Release evidence |
|---------|-----------|---------|-----------|---------|------------------|
| completed | yes | yes | yes | yes | yes |
| degraded | no (distinct state) | yes | yes | yes | yes |
| partial | no | no | no | yes | no |
| truncated | no | no | no | yes | no |
| cancelled | no | no | no | yes | no |
| deadlineExceeded | no | no | no | yes | no |
| targetChanged | no | no | no | yes | yes |
| secureTarget | no | no | no | no | no |
| failed | no | no | no | yes | no |
| abandonedDuringShutdown | no | no | no | yes | no |

Notes:

- `partial`/`truncated` text is never silently persisted as finished
  dictation and never triggers the success animation.
- `secureTarget` also prohibits metrics with payloads; anonymous lifecycle
  counts may still be emitted but are excluded from payload diagnostics.
- Release evidence is reserved for outcomes that are reproducible and
  payload-safe (`completed`, `degraded`, `targetChanged`).

## 5. Terminology rules for product surfaces

- "Inserted" (green) requires `verifiedInserted` and a `completed` session.
- "Paste sent — verify destination" replaces "Inserted" for `eventPostedUnverified`.
- "Partial", "degraded", "truncated" and "cancelled" are user-visible words
  with the same meaning as `StageOutcomeCategory` cases.

## 6. Validation

- `SessionOutcome.swift` — exhaustive policy switch (adding an outcome breaks
  compilation until policy is mapped).
- `SessionTerminalGate` — exactly-once terminal admission (JOE-2240).
- Unit tests cover each outcome's policy and the terminal guard.
