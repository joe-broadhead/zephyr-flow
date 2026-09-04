# Flow backend capability contract (JOE-2276)

The deterministic rules backend (`EnhancedFlowProcessor`) is declared through
`FlowCapability.enhancedRules` in
`Sources/ZephyrFlowCore/FlowCapabilities.swift`. Routing code queries the
capability table — never scattered backend checks.

## Capability of the rules backend

| Field | Value | Meaning |
|-------|-------|---------|
| id | `io.zephyr-flow.flow.rules.v1` | canonical identity |
| version | `1.0` | capability schema version |
| networkUse | `.none` | no network, ever |
| requiresModelWeights | `false` | no model weights / no LLM |
| isDeterministic | `true` | same input → same output |
| styles | clean, bullets, professional, summary, raw | all styles |
| enhancedStyles | bullets, professional, summary | these get enhanced rewrites |
| lossClasses | all (`FlowLossClass.allCases`) | preserved across transformation |
| languages | `["en"]` | first-class rules; other locales: conservative regex only |
| cancellation | `.cooperative` | `Task.isCancelled` checked between passes |
| resourceRequirement | ≤ 32 MB (measured) | CPU-only; no 4GB/16GB RAM gates |
| entryGate | `.deterministicRules` | no extra gate |

## RAM gates removed

The previous 4 GB (`NeuralFlowProcessor.meetsRAMGate`) and 16 GB
(`neuralMinimumRAMBytes`) gates were inconsistent, unbounded claims about a
deterministic rules path. The rules engine performs light CPU work only; it is
always ready and Auto selection is never memory-blocked for the rules path.

## Terminology audit result (per repository scan)

- `NeuralFlowProcessor` renamed to `EnhancedFlowProcessor`.
- `FlowRouter.configure(backend:neuralReady:neural:)` legacy alias removed.
- `FlowBackend.neural` public static alias removed; the `neural` raw string is
  migration-only and maps to `.enhanced`.
- The 16 GB settings gate deleted; the 4 GB processor gate deleted.
- Remaining `neural` references exist only for (a) legacy settings migration
  compatibility and (b) Apple hardware "Neural Engine" (Whisper, accurate).
- `FlowGuardrails` comment corrected from "neural Flow output" to "enhanced".

## Future semantic backends

A future LLM/semantic backend must declare a distinct `FlowCapability`
(`entryGate: .semanticModelRequiresEvidence`), pass the capability and evidence
gate, and is never admissible as the rules identity.
