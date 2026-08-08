# JOE-2290 — transactional Launch at Login

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/LaunchAtLoginPolicy.swift`, AppKit-free)

- `LaunchAtLoginState`: registered / notRegistered / requiresApproval /
  notFound (unpackaged dev) / denied / unsupported / stale.
- `LaunchAtLoginTransaction`: idle → pending → applied (commit) / rolledBack;
  desired value is cleared on rollback — no false enabled/disabled setting is
  ever persisted; commit without begin refused.
- `statusConverges(status:desiredEnabled:)` — only registered/notRegistered
  converge; approval/not-found/denied/unsupported/stale surface to the user.

## App wiring

- `LaunchAtLoginService`: authoritative `SMAppService.mainApp.status` read on
  launch/settings-open; `apply(enabled:)` runs the transaction
  (pending → register/unregister → verify → commit/rollback); typed
  diagnostics; `openLoginItemsSettings()` recovery; `availabilityMessage()`
  explains unpackaged/unsupported/approval states.
- SettingsView toggle: pending state; commits settings ONLY after verified
  convergence; on rollback settings JSON keeps the verified system state and a
  persistent actionable error is shown.

## Acceptance criteria

- UI converges to verified system status after success/failure/relaunch —
  transaction + statusConverges.
- Failed registration/unregistration leaves no false enabled/disabled —
  rollback tests.
- Development/unpackaged builds explain unavailability — availabilityMessage.
- Login Items approval/revocation detected and recoverable — requiresApproval
  + openLoginItemsSettings.
- Migration/reset does not unexpectedly register/unregister — transaction
  only applies on explicit toggle.

## Deterministic tests (JOE-2290 block)

Pending/commit; rollback clears desired; convergence rules (registered/
notRegistered; approval/notFound/stale never converge); failed unregister
rolls back; commit without begin refused. All pass.

## Remaining manual validation (human gate)

Real signed-app install/enable/reboot/disable/uninstall qualification +
screenshots + status-transition report (runbook retained).
