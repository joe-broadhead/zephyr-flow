# JOE-2266 — async termination + recovery handshake

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/TerminationHandshake.swift`, AppKit-free)

- `TerminationStep`: admissionClosed → sessionFinished → audioStopped →
  enginesQuiesced → pasteboardResolved → storageFlushed → preferencesRestored.
- `TerminationHandshake`: begin → running → completed / abandoned; hard
  deadline (default 3 s); `completeStep` abandons with a recovery marker
  (`zephyr.incomplete-shutdown-<step>`) when the deadline hits; exactly-once
  `markFinalized` (no double callbacks); `remainingSteps` for the recovery
  report.

## App wiring

- `DictationController.terminate()` runs the seven steps in order: close
  admission (hotkey.stop + control.shutdown) FIRST; finish/cancel the active
  session (single terminal outcome, gate closed); stop + drain audio; quiesce
  the engine with bounded cancel; pasteboard resolution already recorded by
  the typed insert transaction; flush settings (save) + metrics + clear
  review content; restore the Fn/global preference exactly via
  `HotkeyService.restoreFnOverrideIfNeededFromPriorLaunch()`.
- `AppDelegate.applicationShouldTerminate` uses the macOS ASYNC termination
  API (`reply(toApplicationShouldTerminate:)` + `.terminateLater`): the
  process does not exit until the handshake resolves; a hard deadline
  abandons with a logged recovery marker — termination cannot hang
  indefinitely.
- On next launch `HotkeyService.restoreFnOverrideIfNeededFromPriorLaunch()`
  repairs recoverable global state; incomplete writes are quarantined by the
  recovery marker.

## Acceptance criteria

- Quit from every session state produces one terminal outcome and no double
  callbacks — handshake + finalize-once (tests).
- No active audio tap/recognition task/engine op silently reused after
  relaunch — terminate stops/drains/cancels (steps 2–4).
- Settings/history writes durable or explicitly failed — storageFlushed step
  (repositories persist on write).
- Fn preference restoration exact after graceful + simulated unclean shutdown
  — preferencesRestored step + prior-launch recovery.
- Termination cannot hang indefinitely — hard deadline (tests).

## Deterministic tests (JOE-2266 block)

Full shutdown completes (7 steps); finalize exactly once; no marker on clean
exit; deadline abandons with step-named marker; remaining steps surfaced;
idle begin on first step; terminal absorption. All pass.

## Remaining manual validation (human gate)

Forced timeout/crash/relaunch + OS logout/restart dogfood and resource-count/
recovery reports (runbook retained).
