# JOE-2243 — AppEnvironment + dependency-injected subsystem boundaries

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Delivered

- `Sources/ZephyrFlowCore/AppEnvironment.swift`: composition root with
  protocol-backed dependencies — ClockProviding, Sleeper, IDGenerating,
  MetricsSinking, SettingsRepository, HistoryRepository,
  PermissionProviding, TargetValidationProviding + EngineRegistry, Flow,
  Insertion; `AppEnvironment.test(...)` fully deterministic fakes:
  FakeClock (controllable), FakeSleeper (records, no real wait),
  FakeIDGenerator, RecordingMetricsSink, StaticSettingsRepository,
  InMemoryHistoryRepository, FakePermissionProvider, FakeWhisperEngine,
  FakeInsertionService, FakeTargetValidation.
- `Sources/ZephyrFlow/App/AppEnvironment+Production.swift`: one-time
  production assembly (SystemClock/SystemSleeper/SystemIDGenerator/
  ZFLogMetricsSink/SettingsStoreRepository/HistoryStoreRepository/
  PrivacyPermissionProvider + real subsystems).
- `DictationController` now receives `AppEnvironment` (init) and uses
  environment.clock/sleeper/settings/history/flow/insertion/targetValidation/
  engines; `InsertionServiceProtocol` extended with the full-parameter
  insertion so DI fakes satisfy the production call shape.
- Composition-root doc: docs/development/contracts/app-environment.md.

## Acceptance criteria

- DictationController no longer fetches concrete global `.shared` for
  insertion/flow/target internally — migrated to environment protocols.
- A unit test constructs the full session pipeline using only fakes — test.
- Dependency lifetimes and actor isolation explicit — protocols + one-time
  production assembly.
- Test environments inject deterministic time/failure/cancellation/stale
  callbacks — FakeClock/FakeSleeper/FakeIDGenerator + tests.
- No production dependency performs work as a side effect of static init —
  production() is called explicitly at launch.

## Deterministic tests (JOE-2243 block)

Fake clock injectable + controllable; fake permissions/settings; fake engine
in registry; fake pipeline (start→append→finalize complete); fake insertion
verified; fake target available; test env has no side effects. All pass.

## Remaining (documented) manual items

Full migration of UI/infrastructure singletons (FloatingPanelController,
ModelReadinessStore, FocusStore, PrivacyService, HotkeyService) into the
environment — currently production providers only; static grep guard
documented in the contract doc.
