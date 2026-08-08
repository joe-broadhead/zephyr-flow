# JOE-2277 — language-aware, paragraph-preserving deterministic Flow rules

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## What changed (Sources/ZephyrFlowCore/FlowProcessor.swift + FlowRouter + EnhancedFlowProcessor)

- **Language-aware**: `process(_:style:language:)` threaded through the
  protocol (extension default .auto), FlowRouter (with JOE-2276 eligibility +
  enhanced timeout guardrails) and EnhancedFlowProcessor. English
  filler/contraction heuristics apply ONLY to qualified English locales
  (auto or bcp47 starts with "en"); fixed non-English locales receive
  whitespace/punctuation-safe behavior per the loss-class spec.
- **Paragraph-preserving**: clean() splits on newlines, cleans each line,
  preserves blank-line paragraph breaks (`
{2,}`), collapses only
  intra-line whitespace. Professional no longer collapses `

`.
- **Ambiguous contractions removed**: I'd / it's / that's / there's are left
  intact (context-dependent meaning). Unambiguous (can't→cannot, won't→will
  not, don't→do not, …) still expand for English only.
- **Protected technical spans**: URLs, emails, paths, versions, abbreviations,
  double-quoted spans and backtick code are extracted to placeholders before
  sentence rules and restored afterwards (byte/canonical equivalent).
  Non-overlapping selection fixes path-inside-URL corruption; capitalization
  runs on protected text, then spans restore.
- **Single quotes NOT treated as quotes** (apostrophes in contractions stay
  editable).
- **Precompiled regexes** (static, no per-call compilation); English extras
  precompiled in EnhancedFlowProcessor.
- **Unicode-safe capitalization** (Character-based) that skips placeholders.

## Acceptance criteria

- Non-English fixtures preserve lexical content aside from approved
  whitespace/punctuation normalization — tests (de-DE).
- Paragraph breaks survive clean/professional — test.
- Ambiguous contractions not forced — test.
- Protected technical spans byte/canonical equivalent — tests (URL/email/
  version/quoted).
- Existing safe filler removal covered for English — test.
- No per-call regex compilation regression — static precompiled patterns.

## Deterministic tests (JOE-2277 block)

Paragraph preservation; non-English lexical preservation + filler untouched;
English filler removal; ambiguous contractions preserved; unambiguous
expansion; non-English contraction untouched; URL/email/version/quoted span
protection. All pass.

## Remaining manual validation (human gate)

Differential report against previous behavior with every changed case
reviewed (multilingual/paragraph/contraction/technical/Unicode golden set +
real-device dictation in a non-English locale; runbook retained).
