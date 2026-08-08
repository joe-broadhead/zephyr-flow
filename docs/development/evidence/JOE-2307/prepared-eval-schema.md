# JOE-2307 — prepared: unified Zephyr Flow / Aurum evaluation schema (inert)

Blocked by JOE-2294 (real-device) and the JOE-2314 human decision (P5).
This document is the prepared unification contract; nothing is wired to
product code until the Aurum lane opens.

## Schema (v0.1 draft)

```json
{
  "schemaVersion": "0.1",
  "corpus": { "id": "string", "language": "string", "utterances": "int" },
  "utterance": {
    "id": "string", "audioPath": "string", "reference": "string",
    "expected": ["string"]
  },
  "run": {
    "engine": "whisperkit | aurum",
    "model": "string", "toolchain": "string", "machine": "string",
    "commit": "string", "seeded": "bool", "seed": "uint64"
  },
  "metrics": {
    "wer": "float", "cer": "float",
    "silenceFalsePositiveRate": "float",
    "firstPartialLatencyMs": "float", "endLatencyMs": "float",
    "rssPeakMB": "float", "energyImpact": "float",
    "sessions": "int", "crashes": "int",
    "privacy": { "localOnlyVerified": "bool", "noTranscriptLogs": "bool" }
  }
}
```

## Rules

- Metrics only; transcript bodies are never stored (privacy invariant).
- Preregistered corpora + seeds; identical schema across both engines so the
  JOE-2313 bake-off is comparable.
- Both engines must satisfy the same privacy invariants (Local Only,
  no-transcript logs, at-rest encryption of history).
