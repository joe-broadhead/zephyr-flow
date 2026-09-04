# Flow loss classes and protected-span preservation grammar (JOE-2275)

**Source:** JOE-2275 · milestone M0
**Status:** Accepted contract; implementation JOE-2276/2277/2278, corpus JOE-2280.

## 1. Loss classes

| Class | Allowed operations | Secure/unknown allowed | Consent |
|-------|--------------------|------------------------|---------|
| verbatim | trim/line-ending normalisation only | yes | no |
| conservative | whitespace, punctuation, narrowly approved fillers | yes | no |
| structural | paragraph/bullet formatting, preserves all propositions + protected spans | no | no |
| semantic | summary/professional rewrite | no | **explicit, measured budgets** |

UI terminology must communicate the actual loss class ("Clean" = conservative
filler removal; "Professional" = structural/semantic rewrite).

## 2. Protected-span grammar

Extraction/canonicalisation are **versioned pure functions**. Kinds
(`ProtectedSpanKind`):

- signed/repeated numbers; decimals; grouped digits
- currency, percentages, units, dates, times, durations, versions
- negation (`not`, `never`, `must`, `without`…) and modal constraints
- URLs, email addresses, file paths, command/code spans
- quoted text, issue/commit IDs, identifiers, product/proper names
- paragraph/list boundaries relevant to the selected loss class

Preservation semantics: **ordered multisets with sign/multiplicity/order and
associations** (e.g. currency↔amount, percentage↔number, negation↔span) — not
mere set membership. Each extracted span records `(kind, sourceRange,
canonical, instance)` (`ProtectedSpan`).

## 3. Language applicability

- English-specific filler/contraction heuristics only for qualified English
  locales (`FlowLanguageContext.isEnglishQualified`).
- Non-English input receives whitespace/punctuation-safe conservative
  behavior; no English rewrites.
- Low parsing confidence ⇒ conservative fallback (default-safe).

## 4. Golden fixtures and adversarial examples

- Corpus: `Tests/ZephyrFlowTests/FlowFixtures.swift` + docs table (below).
- Every Flow bug adds a regression fixture (JOE-2280).

## 5. Release budgets

Preregistered per loss class/style/language (JOE-2281, human gate):
zero critical protected-span/sign/unit/identifier/negation violations on the
conservative/structural path; bounded fallback rate; deterministic stability.

## 6. Fixture samples (adversarial)

| Input | Style | Must preserve |
|-------|-------|---------------|
| "transfer -1,234.56 USD by 2026-08-08" | clean | sign, group, decimal, currency, date |
| "do NOT delete the 3 files, never auto-publish" | professional | negation pair, count |
| "call 555-0100 after 9:30 PM" | clean | phone/grouping, time |
| "see https://example.com/a?b=1 and a@b.co" | clean | URL, email |
| "run `rm -rf /tmp/x` then `make`" | bullets | code spans, order |
| "quote: \"hold the line\" — M. Aurelius" | summary | quote, name |
| "Die 3 Dateien nicht löschen" (de) | clean | no English rewrite, count, negation |
