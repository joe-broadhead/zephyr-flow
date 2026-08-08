# JOE-2260 — pasteboard insertion as a lossless bounded transaction

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core model (`Sources/ZephyrFlowCore/PasteboardTransaction.swift`, AppKit-free)

- `PasteboardTypeRecord` / `PasteboardItemSnapshot` / `PasteboardSnapshot`:
  ordered items, every available type with its raw data payload — never
  flattened; byte-for-byte round-trip. `isEmpty` represents an initially
  empty pasteboard explicitly (restore = clear).
- `PasteboardBudget` (reviewed maximums: 8 MB / 64 items / 256 types per
  item). `withinBudget` decides before ANY mutation; overflow aborts the
  transaction with NO destructive clipboard mutation.
- `PasteboardMarker` — unique transaction marker type written alongside the
  temporary content for safe "still ours" equivalence.
- `PasteboardTransaction` — session-scoped value-type state machine
  (ready → temporaryApplied → posted → restored | notRestoredBecauseChanged |
  restoreFailed | cancelled | abandonedDuringShutdown | overBudget); single-
  shot terminal outcomes. `attemptRestore` uses change-count + marker
  equivalence: if the user/target changed the pasteboard it returns
  `notRestoredBecauseChanged` and the new value is never overwritten.
- `PasteboardTransactionPolicy.allowed(sensitivity:)` — secure/unknown can
  never call this transaction (only `.normal`).

## App wiring (`InsertionService.pasteViaClipboard`)

- Snapshots ALL pasteboard items/types/data (ordered) at transaction start.
- Refuses without a session or for non-normal sensitivity (fail closed).
- Refuses on budget overflow (no mutation).
- Applies temporary text + unique marker type; records changeCount.
- Posts Cmd-V; on post failure restores the snapshot safely and cancels.
- Await-bounded restore with equivalence check; restores byte-for-byte
  (all items, all types) or preserves the user/target's new value.
- Post-restore verification (original types/data present, marker gone);
  failure → `restoreFailed`. Outcome counts only — no clipboard payloads in
  logs.

## Acceptance criteria

- Empty/plain-text/image/file-URL/RTF/multi-item fixtures round-trip exactly
  when untouched — model byte-equality tests.
- Failure before/after posting Cmd-V restores safely — post-failure restore +
  transaction cancel tests.
- User/target changes during the window are preserved — equivalence tests.
- Snapshot-budget overflow produces no destructive clipboard mutation — nil
  transaction (no write) tests.
- Secure/unknown sessions cannot call this transaction — policy tests.

## Deterministic tests (JOE-2260 block)

Empty, plain-text, rich multi-item multi-type (text+RTF+image+file URL)
fixtures byte-for-byte; budget detection + refusal; change-window
preservation; single-shot; cancel/shutdown; sensitivity gate. All pass.

## Remaining manual validation (human gate)

Real-AppKit integration tests (actual NSPasteboard round-trip on macOS) and
crash/termination recovery policy exercise — real-device items; runbook below.

### Runbook (human gate)

1. Copy rich content (files+text+image) in Finder/Notes; dictate into a
   normal app; verify clipboard is byte-identical after insertion.
2. Start with empty clipboard; dictate; verify clipboard ends empty.
3. During the paste window, copy something else; verify your content is kept
   and Zephyr reports "Clipboard was left as-is".
4. Kill ZephyrFlow mid-paste; relaunch; verify no stale transcript content on
   the pasteboard (marker cleanup on next launch is logged).
