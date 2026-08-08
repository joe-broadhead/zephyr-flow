# JOE-2261 — opt-in bounded actor history repository

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core

- `HistoryPolicy.swift`: `HistoryRetentionPolicy` (age/bytes/entries),
  `HistoryStorageEntry` (data-minimized: ONE text field, no raw+transformed
  duplication), `HistoryDocument` (schema v2), `HistoryStoragePolicy`
  (default OFF for new installs; writes require normal sensitivity AND
  outcome.permitsHistoryRetention — fail closed without an outcome).
- `ActorHistoryRepository` (actor, Foundation-only): async I/O off the
  MainActor; atomic durable writes (temp + replace + 0600), restrictive
  directory permissions (0700), schema versioning, corruption quarantine
  (.quarantined move + typed error), recoverable v1→v2 migration (single
  text field), retention enforcement, failure-aware clear/delete with typed
  errors (diskFull / permissionDenied / corruptionDetected / migrationFailed).
- `HistoryFileSystem`/`RealHistoryFileSystem`: injectable FS boundary
  (tests inject failing/corrupting adapters).

## Wiring

- `AppSettings.saveHistory` default → false (opt-in); existing explicit
  choices preserved via SettingsStore migration.
- Production `HistoryStoreRepository` → `ActorHistoryRepository.shared`.
- DictationController history gate centralized on
  `HistoryStoragePolicy.allowsWrite(sensitivity:outcome:)`.

## Acceptance criteria

- New default opt-in and documented — default false + tests.
- No history file mutation for secure/unknown — policy gate + tests.
- Repository work does not block MainActor — actor-isolated async I/O.
- Disk-full/permission-denied/corruption/interrupted-migration handled — typed
  errors + failing-FS test + quarantine test.
- Retention limits hold under large transcripts/repeated use — trimmed tests.
- Delete/clear durable after relaunch — round-trip/clear tests.

## Deterministic tests (JOE-2261 block)

Default-off; gate matrix (secure/unknown/unverified/no-outcome denied);
retention age/entries/bytes; repo round-trip durable; clear durable; v1
migration to single text; corruption quarantined + reported; failing FS
exercises the typed-error path. All pass.

## Remaining manual validation (human gate)

Real-filesystem permission/retention soak + privacy canary scan of history
files/backups + UI clear/export controls walkthrough (runbook retained).
