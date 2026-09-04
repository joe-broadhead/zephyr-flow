# Invariant/transition coverage map (JOE-2292)

| Invariant / transition | Core artifact | Test block |
|---|---|---|
| Exactly-one terminal outcome | SessionControlModel / DictationSession.finishTerminal | JOE-2246 block; JOE-2292 stress |
| No cross-session attribution | SessionIDFactory + per-session actor/provider | JOE-2244 block; JOE-2292 stress |
| No forbidden sensitive side effects | HistoryStoragePolicy / sensitivity gates | JOE-2261, JOE-2259 blocks; JOE-2292 stress |
| Target validation before mutation | TargetValidationSession | JOE-2268 block; JOE-2292 stress |
| Resource release (leak-free) | exactly-once terminal release | JOE-2244 leak test; JOE-2292 stress |
| Session state machine legality | SessionControlModel transitions | JOE-2246 block |
| Audio bounded/ordered | BoundedAudioChannel + sequencer | JOE-2247/2248 blocks |
| Flow fidelity/guardrails | FlowFidelityCorpus + FlowGuardrails | JOE-2277..2281 blocks |
| Insertion outcomes | InsertionOutcome + AxWritePolicy | JOE-2269/2270 blocks |
| Verified model lifecycle | ModelAcquisitionController | JOE-2255 block |
| Generation-safe selection | ModelSelectionTracker | JOE-2256 block |
| At-rest encryption | HistoryCipherEngine | JOE-2262 block |
| Capability onboarding | CapabilityGraph | JOE-2282 block |
| First-run model UX | ModelUIPolicy | JOE-2283 block |
| Localization readiness | AppStrings + string_scan | JOE-2289 block |
