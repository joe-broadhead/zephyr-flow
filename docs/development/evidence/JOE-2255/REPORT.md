# JOE-2255 — verified model acquisition/cache lifecycle

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/ModelAcquisition.swift`, AppKit-free)

- `ModelAcquisitionState`: missing/queued/downloading/verifying/ready/
  cancelled/quarantined/failed.
- `ModelManifest` (schema 1): engine identity, model ID, expected artifact
  set, size bounds, SHA-256 digests where the upstream format permits;
  injectable `manifestProvider` for reviewed metadata.
- `ModelAcquisitionController` (actor): per-model singleflight (concurrent
  preloads = one acquisition, consistent results), staging -> verify
  (completeness + digests + size bounds) -> ATOMIC promote, quarantine of
  corrupt/incomplete content, stale-lock cleanup, cancellation, structured
  progress, typed errors (consentDenied/downloadFailed/verificationFailed/
  promotionFailed/cancelled/staleLockDetected).
- `verifiedReadiness(for:)`: readiness = VERIFIED loadability (manifest +
  verified URL), never a non-empty directory.
- `ModelReadinessState` extended with queued/verifying/cancelled/quarantined.

## App wiring

- `ProductionModelAcquisitionFileSystem`: app-owned stable cache at
  Application Support/ZephyrFlow/VerifiedModels (0700 dirs), manifest
  read/write, atomic promote, quarantine, sha256 (CryptoKit), stale-lock
  detection (5 min), downloader stages a private copy of the WhisperKit-
  downloaded folder (never symlinks into third-party caches).
- `ModelReadinessStore`: readiness from the verified controller; acquire()
  with singleflight; maps states to UI.
- `DictationController.preloadEngine`: verified-cache fast path; consent
  (`allowModelDownloads`) gates acquisition independently of Local Only audio
  policy; Local Only + missing model + no consent fails cleanly.

## Acceptance criteria

- Interrupted/corrupt downloads never become ready — fault-injection tests.
- Concurrent preloads perform one acquisition with consistent results —
  singleflight test.
- Local/offline mode fails cleanly when a verified model is absent — test 8.
- Cache permissions restrictive + documented — 0700 assertions.
- Readiness = verified loadability, not a non-empty dir — test 11.

## Deterministic tests (25 JOE-2255 checks)

Happy path; verified URL; 0700 cache/staging perms; download failure typed;
digest mismatch -> quarantined; correct digest -> ready; truncated artifact ->
quarantined; promotion failure; singleflight consistency; consent denied;
offline missing fails cleanly; stale-lock recovery; cancel mid-download;
manifest-less dir not ready. All pass.

## Remaining manual validation (human gate)

Real WhisperKit model download qualification (first-run UX, network failure/
retry on a real machine) — runbook retained.
