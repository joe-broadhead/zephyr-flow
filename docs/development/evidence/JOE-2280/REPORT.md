# JOE-2280 — versioned Flow fidelity corpus + differential harness

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Corpus (`Sources/ZephyrFlowCore/FlowFidelityCorpus.swift`, version 1)

24 license-clean, deterministic cases across every contract dimension:
- natural dictation with fillers/repairs/punctuation (nat-001/002)
- signed/repeated numbers, currency, percent, units, versions (num-001..004)
- negation/constraints/modals (neg-001/002)
- names/product/issue/commit identifiers (id-001/002)
- URLs/emails/paths/code/quotes (tech-001..003)
- paragraph/list structure (para-001/002)
- financial/legal/medical caution cases (fin/leg/med-001)
- non-English locales de-DE/fr-FR + language-mismatch (i18n-001/002)
- empty/short/long/adversarial edges (edge-001..004)

Each case records id, category, language, style, forbidden tokens and golden
output where deterministic.

## Harness (JOE-2280 test block)

For every case: run FlowProcessor (deterministic rules) twice (stability),
check protected-span preservation (FlowGuardrails inputCovered), forbidden
tokens absent, golden equality; write a structured report
(`/tmp/flow-fidelity-report.json`, copied to evidence/). Result:
- totalCases 24 · protectedSpansPreserved 24 · forbiddenChangesAbsent 24 ·
  deterministicRuns 24 · goldenExact 2 · failures [] (corpus-report.json).

## Fidelity fixes surfaced by the corpus

- Trailing-sentence punctuation no longer part of URL/email/path tokens.
- Filler removal no longer leaves intra-line double spaces.

## Remaining manual validation (human gate)

Human semantic-review scorecards for the caution/i18n/adversarial cases and a
real-device differential run across engines/versions (runbook retained).
