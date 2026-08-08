# JOE-2281 — preregistered Flow release budgets + exact-candidate gate

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/FlowReleasePolicy.swift`)

- `FlowStyleBudget`: per style — maxCriticalViolations (0 for conservative/
  structural), maxFallbackRate, minDeterministicStability, maxNoopRate.
- `FlowReleasePolicy` (immutable const, versioned): version 1, baseline
  commit `agent/zephyr-production-run-20260808T103416Z@3059542`, corpus
  version locked, per-style budgets. Threshold changes require a new baseline
  version + reviewed rationale; the candidate cannot modify it.
- `FlowStyleStats` + `FlowReleaseGate.evaluate(corpusVersion:stats:policy:)`:
  machine-readable pass/fail; corpus-version mismatch blocks; per-violation
  category + fallback rate surfaced.

## Harness integration

Corpus run computes per-style stats (critical = protected token lost,
fallback = guardrail rejection, noop, stability) and evaluates the gate in
the CLT; report includes the verdict.

## Fidelity fix surfaced by the gate

Summary mode was fact-lossy (first+longest sentences dropped numbers/
negations). `summarize()` is now fact-preserving: it adds any sentence
carrying a protected token not yet covered, so critical facts are never
dropped by the semantic path.

## Acceptance criteria

- Machine-readable policy drives CI pass/fail — FlowReleaseGate + tests.
- Current candidate cannot modify its own thresholds/corpus — immutable const
  + version guards (tests).
- Reports show every violation category and fallback rate — stats + report.
- Critical fact/negation errors block — summary fact-preservation fix + gate.
- Baseline + allowed regression deltas from a named prior commit — baseline
  named; corpus version locked.

## Deterministic tests (JOE-2281 block)

Gate passes on the corpus (all styles zero critical violations, stability 1.0,
fallback within budget); policy versioned + baseline named; corpus mismatch
blocks. All pass.

## Remaining manual validation (human gate)

Human review scorecard for semantic modes (separate from automatic gates) +
threshold-change rationale process (runbook retained).
