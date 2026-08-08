# JOE-2286 — exact + transactional Fn/Globe preference override

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`
**Provisional assumption (recorded in docs/development/prime-agent-run/provisional-decisions.md):**
Fn/Globe remains the default hotkey; the AppleFnUsageType override is retained
BUT only as an explicit experimental opt-in (`HotkeyConfig.experimentalFnOverride`,
default false). The production default path never touches the preference. This
assumption is reversible: flipping the opt-in default to false removes all
preference mutation while qualified Fn handling (CGEvent tap + maskSecondaryFn)
keeps working.

## Core (`Sources/ZephyrFlowCore/FnPreferenceTransaction.swift`, AppKit-free)

- `FnPreferenceSnapshot`: EXACT prior state — key presence, value, CF type tag
  (CFNumber/CFString/CFBoolean/CFType-N), suite + key name (not just `Int?`).
- `FnPreferenceRecord`: versioned transaction record (monotonic version) with
  status `idle/pendingApply/applied/pendingRestore/restored/failedRestore`;
  `isActiveOverride` — a COMPLETED transaction (restored/failedRestore) is
  never an active override.
- `FnPreferenceTransaction`: begin-apply writes the record BEFORE mutation;
  apply marks atomically; begin-restore never re-applies; finish-restore
  verifies exact state and on failure disables capture + surfaces a
  persistent recovery action (`failedRestore`).
- `recoverAfterCrash()`: idempotent — pendingApply -> idle (mutation never
  confirmed), applied/pendingRestore -> pendingRestore (must restore),
  idle/restored/failedRestore unchanged; recovery is idempotent.
- `FnOverridePolicy.shouldOverride` = experimentalOptIn && fn && tapPrepared;
  `shouldRestoreImmediately` = changed-away-from-Fn OR lost permission.

## App wiring (`Sources/ZephyrFlow/Services/HotkeyService.swift`)

- Override begins ONLY after explicit opt-in AND successful tap preparation
  (restartEngine), never on the default path.
- Snapshot exact state (presence/value/CF type via CFGetTypeID); versioned
  record persisted before mutation and after apply.
- Restore is presence-aware — never an unconditional key removal after a value
  was present; verified by read-back; on failure `fnRecoveryRequired` +
  `lastError` surface a persistent recovery action and capture is disabled
  (no automatic reapply).
- Changing away from Fn or losing Accessibility restores immediately.
- Crash recovery (static, prior launch) reads the versioned record and
  resolves it idempotently; legacy pre-2286 marker is also honored.

## Acceptance criteria + deterministic tests (30 JOE-2286 checks)

- Nil/integer/unexpected-value fixtures restore exactly (absent key stays
  absent; CFString type captured) — ✓
- Crash at every transaction step recovers idempotently (all six statuses,
  recovery twice) — ✓
- Restore failure disables capture + surfaces recovery, never auto-reapplies —
  ✓
- Production default path never overrides (opt-in required + tap prepared) — ✓
- Version monotonicity; completed transaction != active override — ✓

## Remaining manual validation (human gate)

Real macOS verification across supported versions (before/after synthetic
preference-state evidence) — runbook in the human-gate pass.
