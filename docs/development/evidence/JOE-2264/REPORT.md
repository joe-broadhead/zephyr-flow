# JOE-2264 — versioned privacy-safe telemetry + exactly-one terminal guard

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/SessionTelemetry.swift`, AppKit-free)

- `TelemetrySchemaVersion` (v1) + typed `TelemetryEvent` (schemaVersion,
  anonymous per-session id, kind, terminal category, stage, engine identity,
  monotonic durations, frame counts, completeness, flow status/loss class,
  insertion confidence, atNanos) — NO free-form labels by construction.
- `SessionTelemetryID`: anonymous per-session, not stable cross-install.
- `TerminalGuard`: exactly one terminal event; second finalize refused;
  dropping an unfinished guard emits a controlled `.abandonedDuringShutdown`.
- `BoundedEventSink`: bounded nonblocking buffer; overflow increments
  droppedCount and never stalls; host callbacks only on explicit drain, never
  under the lock (reentrant hosts cannot deadlock).
- `PrivacyCanary`: scans serialized events for forbidden payload shapes
  (keys, private paths, credential forms); typed schemas make positives a
  schema violation.

## App wiring

- `DictationController` creates a TerminalGuard per session and emits the
  exactly-one terminal event at session end (category from the control-plane
  terminal state); guard cleared on terminal.

## Acceptance criteria

- Every session produces one and only one terminal event — TerminalGuard +
  tests.
- Schemas contain no transcript/audio/API-key/private-path fields — typed
  enums + canary tests.
- Queue saturation does not block the session and is observable —
  BoundedEventSink drop counter (tests).
- Reentrant/slow sinks cannot deadlock metrics — drain-only host calls
  (tests).
- Support tooling can explain stage timings/frame mismatches/fallback/
  insertion confidence — typed event fields.

## Deterministic tests (JOE-2264 block)

Terminal emitted once + second refused + abandon on drop; canary clean on
typed events + detects private path/key shapes; sink overflow drops counted,
never blocks, drains to host; reentrant sink no deadlock. All pass.

## Remaining manual validation (human gate)

Schema golden fixtures + example redacted support record retained; real-device
support-tooling walkthrough (runbook).
