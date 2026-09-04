# AppEnvironment composition root (JOE-2243)

```
                    ┌─────────────────────────────────────────────┐
                    │           AppEnvironment (struct)           │
                    │  clock · sleeper · idGenerator · metrics     │
                    │  settings · history · permissions            │
                    │  engines(registry) · flow · insertion        │
                    │  targetValidation                            │
                    └───────┬──────────────────┬──────────────────┘
                            │ production        │ test
              ┌─────────────▼───────┐   ┌───────▼──────────────────┐
              │ AppEnvironment.     │   │ AppEnvironment.test(...) │
              │ production()        │   │ FakeClock/FakeSleeper/   │
              │ (real singletons:   │   │ FakeIDGenerator/         │
              │  SettingsStore,     │   │ RecordingMetricsSink/    │
              │  HistoryStore,      │   │ InMemoryHistory/         │
              │  PrivacyService,    │   │ StaticSettings/          │
              │  FlowRouter.shared, │   │ FakePermissions/         │
              │  InsertionService,  │   │ FakeWhisperEngine/       │
              │  TargetValidation,  │   │ FakeInsertionService/    │
              │  Whisper/Apple)     │   │ FakeTargetValidation)    │
              └─────────────────────┘   └──────────────────────────┘
```

- Session-domain code (DictationController) receives dependencies through the
  environment; it no longer constructs `InsertionService.shared`,
  `FlowRouter.shared`, `TargetValidationService.shared` internally, and uses
  `environment.clock/sleeper/settings/history/flow/insertion/targetValidation/
  engines`.
- Deterministic protocols: ClockProviding, Sleeper, IDGenerating,
  MetricsSinking, SettingsRepository, HistoryRepository,
  PermissionProviding, TargetValidationProviding, InsertionServiceProtocol,
  FlowProcessorProtocol, WhisperEngineProtocol.
- Fakes inject deterministic time, failure, cancellation and stale callbacks
  without touching real UserDefaults/files/pasteboard/event taps/permissions/
  models/wall clock.
- Production assembly happens once at launch (no work as a side effect of
  static initialization).
- Allowed remaining UI/infrastructure singletons (production providers only):
  FloatingPanelController, ModelReadinessStore, FocusStore, PrivacyService,
  HotkeyService, SettingsStore, HistoryStore. Static check: no NEW `.shared`
  lookups in `Sources/ZephyrFlow/Services/DictationController.swift` beyond
  the documented production providers.
