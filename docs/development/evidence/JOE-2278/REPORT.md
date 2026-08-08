# JOE-2278 — expanded Flow guardrails (sign/multiset/negation/protected ids)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/FlowGuardrails.swift`)

- Typed `ProtectedToken` (kind + canonical value, sign preserved): number,
  percent, currency, unit, version, dateTime, duration, url, email, path,
  code, quoted, identifier (issue/commit IDs), negation.
- Tokenizer: broader kinds (URL/path/code/quoted) cover inner numbers;
  non-overlapping spans; signed numbers `-?\d+...`; percent/currency/unit
  associations; versions (`v1.2.3` / `1.2.3`); dates/times; issue/commit IDs;
  negation words canonicalized (`can't`→`cannot` so approved expansions are
  NOT treated as removal).
- Multiset comparison preserves multiplicity; structural equivalence
  explicit (12000 ↔ 12,000 via canonicalizeNumber).
- `evaluate(input:output:conservativeFallback:)` → approved or rejected with
  controlled reason: emptyOutput / preamble / extremeExpansion / novelNumber /
  droppedNumber / signFlipped / droppedMultiplicity / droppedNegation /
  droppedProtectedToken / droppedPercent / droppedCurrency / droppedUnit.
- On rejection the caller returns the approved conservative fallback; never
  unsafe output.

## Wiring

- `EnhancedFlowProcessor.process(_:style:language:)` runs every enhanced
  transformation through `FlowGuardrails.evaluate`; rejection → conservative
  regex fallback + content-free reason log.

## Acceptance criteria

- `-5` cannot become `5` — sign-preserved tokens (test).
- Repeated numbers cannot collapse/duplicate unnoticed — multiset
  multiplicity (tests).
- `10%`, `$10`, `10 ms`, `v1.2.3` retain associated semantics — typed tokens
  (tests).
- Negation removal/inversion rejected — negation tokens (tests).
- Dropping every number fails conservative/structural guards — tests.
- Technical identifiers + URLs protected — tests.
- Structural equivalence allowed (12000 ↔ 12,000) — test.
- Empty/preamble/extreme-expansion retained as controlled reasons — tests.

## Deterministic tests (JOE-2278 block)

Sign flip; multiplicity drop/duplicate; percent/currency/unit/version drop;
negation removal (do not/never); drop-all-numbers; issue-id/url drop;
structural equivalence allowed; approved output passes; empty/preamble
reasons. All pass.

## Remaining manual validation (human gate)

Differential golden-set review across all changed cases (real-device
dictation with numbers/negations/technical text; runbook retained).
