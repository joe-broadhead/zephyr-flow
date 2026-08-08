# TargetSnapshot contract (JOE-2267)

**Source:** JOE-2267 · milestone M0  
**Status:** Accepted contract; validation implementation JOE-2268.

## 1. Purpose

`TargetSnapshot` is the immutable evidence captured **before** any Zephyr UI
interaction that identifies the intended insertion target and its sensitivity.
Automatic insertion must never occur without a snapshot that revalidates at
write time.

## 2. Snapshot contents

`Sources/ZephyrFlowCore/TargetSnapshot.swift` defines:

| Field | Description | Required |
|-------|-------------|----------|
| `sessionID` | owning session | yes |
| `capturedAtUptimeNanos` | continuous clock | yes |
| target pid / bundleID | process identity | yes / when available |
| processStartUptimeNanos | audit identity detects PID reuse | practical |
| windowID | CGWindowID | when available |
| appVersion | target version | when available |
| element role/subrole/resolutionToken | focused AX identity/reresolve | when available |
| settable/editable/enabled | write capabilities | when available |
| selectionRange | positional only, never field contents | no |
| sensitivity + source | normal/secure/unknown | yes |

## 3. Rules

1. Capture precedence: actively focused app → focused AX application → saved
   focus (only if validated); never silently reuse stale last target.
2. The snapshot can never identify Zephyr itself or an ignored system process
   (`isUsableTarget(zephyrPIDs:ignoredSystemPIDs:)`).
3. Missing AX evidence ⇒ `unknown` sensitivity and `TargetConfidence.unknown`.
4. Snapshot is immutable and session-scoped.
5. Diagnostics serialization contains no field text or private document title
   unless explicitly approved.

## 4. Validation-time checks (JOE-2268 — implemented)

- PID/process-start/window/element-token/role-subrole/editable compare before
  write via `TargetValidationSession` (`Sources/ZephyrFlowCore/
  TargetRevalidation.swift`); bounded observable restore via
  `TargetRestoreMonitor`, never a blind sleep.
- Outcomes: validated / targetChanged / targetGone / targetUnknown /
  secureTarget / notEditable / deadlineExceeded; any non-validated outcome ⇒
  zero transcript-bearing side effects.
- No stale `lastBundleID` fallback: the session-scoped snapshot is the only
  insertion authority.
- Serialized snapshot for diagnostics: positional metadata only.
