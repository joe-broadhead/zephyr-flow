# JOE-2265 — user-reviewable privacy-safe support bundle + canary scanner

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SupportBundle.swift`, AppKit-free)

- `SupportBundleInputs` (controlled, content-free getters) + versioned
  `SupportBundleDocument` (schema 1): app/build/provenance/channel, macOS/
  arch/hardware, permission status, redacted settings summary, engine/model,
  model-cache readiness/integrity, bounded telemetry events (≤256), frame/
  fallback/insertion-confidence summaries, health checks, privacy-policy
  version.
- `SupportBundleCanary`: denylist + forbidden-content markers (keys, private
  paths); `scanField` returns the offending FIELD NAME (never the marker
  value); fail closed.
- `SupportBundleBuilder.build(inputs:)` — explicit user action only; canary
  scans every controlled field; size bound (2 MB); typed failures
  (markerDetected(field) / serializationFailed / sizeLimitExceeded); atomic
  export; readable `preview` manifest.

## Acceptance criteria

- Injected canary transcript/API-key/private-path markers never appear in a
  successful bundle — canary tests.
- A detected marker prevents export and names the offending field without
  revealing the marker — markerDetected(field) tests.
- Bundle is sufficient to diagnose representative permission/model/frame/
  timeout/insertion failures — inputs include all categories.
- Schema versioned and golden-tested — schemaVersion + tests.

## Deterministic tests (JOE-2265 block)

Clean bundle builds + canary clean; preview manifest; marker prevents export;
offending field named (settingsSummary.notes); private-path marker blocks;
telemetry events bounded; bundle carries permissions/model/frames/fallback/
confidence. All pass.

## Remaining manual validation (human gate)

Support scenarios reviewed using only generated bundles + synthetic example
bundle + schema docs (runbook retained).
