# JOE-2263 — versioned settings storage (transactional migrations + quarantine)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SettingsStorage.swift`, AppKit-free)

- `SettingsEnvelope`: schemaVersion + payload + migrationProvenance.
- `SettingsStorageCoordinator`:
  - load(data:) — nil (fresh install) => documented privacy-safe defaults;
    current envelope => decode; legacy v1 flat payload => deterministic
    migration (provenance recorded); corrupt/unknown-newer schema =>
    quarantine name + SAFE baseline (localOnly ON, downloads/history OFF) +
    recovery flags (never silent defaults).
  - encode(settings:provenance:) — atomic; throws `writeFailed` so the UI
    never claims a change that was not durably committed.
  - resetPayload(current:) — transactional reset preserving ONLY documented
    fields (onboarding completion).

## Wiring (`SettingsStore`)

- Load uses the coordinator; on corruption the ORIGINAL bytes are quarantined
  under a recovery key and the safe baseline is activated with a published
  recoveryState (.recoveredFromCorruption / .unknownSchema(n)).
- Commit returns Bool; save() reports failure; reset is transactional.

## Acceptance criteria

- Every historical fixture migrates deterministically — v1 flat test.
- Unknown/newer schema fails safely and retains original for recovery —
  unknownSchema + quarantine test.
- Write failure does not leave UI claiming a setting changed — encode throws;
  commit reports failure.
- Privacy-affecting defaults not silently re-enabled after corruption —
  safe-baseline test (localOnly on, downloads/history off).
- Reset preserves only documented fields and is transactional — reset test.

## Deterministic tests (JOE-2263 block)

Envelope round-trip; v1 flat migration; unknown schema fails safely with
quarantine; corruption baseline privacy-safe; corrupt data recovered; fresh
install defaults privacy-safe; reset transactional + onboarding-only;
encode succeeds. All pass.

## Remaining manual validation (human gate)

Golden migration fixtures + disk-full/permission/truncated fault injection on
real UserDefaults + recovery UX screenshots/docs (runbook retained).
