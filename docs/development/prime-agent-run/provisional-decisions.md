# Provisional Decisions (run 20260808T103416Z)

This file records every conservative, reversible provisional assumption made
on the review branch when a human-gated contract blocked downstream work.
Each entry names the blocking gate, the assumption, why it is safe/reversible,
and the exact un-block action. Human-gated issues themselves are NEVER marked
Done; they carry `ready_for_human_gate` / `deferred_by_contract`.

## P1 — Hotkey default stays Fn/Globe (blocks JOE-2285 -> JOE-2286/2287)

- **Blocking gate:** JOE-2285 (human decision: adopt a conventional
  configurable production hotkey vs retain Fn/Globe).
- **Provisional assumption:** Fn/Globe remains the default hotkey and is the
  only shape delivered in this run. The AppleFnUsageType system-preference
  override is retained ONLY behind an explicit experimental opt-in
  (`HotkeyConfig.experimentalFnOverride`, default `false`), so the production
  default path never touches the preference (JOE-2286 acceptance).
- **Why safe/reversible:** no API/UX promise; the opt-in flag defaults to off;
  qualified Fn handling (CGEvent tap + `maskSecondaryFn`) works without the
  mutation. Flipping the flag off removes all preference writes.
- **Implemented under this assumption:** JOE-2286 (276cfe0), JOE-2287
  (276cfe0).
- **Un-block action:** human picks JOE-2285; if a conventional hotkey is
  adopted, wire it into `HotkeyConfig`/Settings (already supports keyCode +
  modifiers for standard chords) and decide the Fn opt-in default.

## P2 — Release channels deferred; preview = current ad-hoc path (blocks JOE-2298 -> 2299-2304)

- **Blocking gate:** JOE-2298 (human: split preview and production release
  channels; production must gate on notarization).
- **Provisional assumption:** no production channel is created in this run.
  The existing ad-hoc build path (`Scripts/build_app.sh debug`) remains the
  preview path only; nothing is published. Supply-chain hardening
  (JOE-2300/2301/2302/2304) is prepared as dry-run manifests/scripts but not
  wired to a live production pipeline.
- **Why safe/reversible:** no release artifacts, no tags, no public channel;
  the prepared scripts are inert until the channel decision lands.
- **Un-block action:** human decides JOE-2298; then adopt the prepared
  `Scripts/release/supply-chain` manifests (exact-tag checkout, SBOM,
  signed update manifest) into the chosen production channel.

## P3 — Apple Developer ID signing deferred (blocks JOE-2299/2309)

- **Blocking gate:** JOE-2299/JOE-2309 (credentials: Apple Developer ID +
  hardened runtime + notarization).
- **Provisional assumption:** no Developer ID signing/notarization is
  attempted; the run never uses production Apple credentials. Ad-hoc signing
  only, per AGENTS.md.
- **Why safe/reversible:** signing/notarization are additive to the built
  app; entitlements (`Resources/ZephyrFlow.entitlements`) and the
  build_app.sh signing step are already parameterised.
- **Un-block action:** human supplies Developer ID credentials; run
  `./Scripts/release/notarize.sh --dry-run` then the real flow (runbook in
  human-gates.md).

## P4 — Real-device evidence deferred (blocks JOE-2294 -> 2295/2296/2297/2303/2307-2314)

- **Blocking gate:** JOE-2294 (real-speech observatory on actual hardware)
  and the real-device qualification issues.
- **Provisional assumption:** deterministic fakes/CLT tests are the
  authoritative in-run evidence; real-microphone/device/app-matrix outcomes
  are NOT claimed. All real-device issues carry exact runbooks and prepared
  harnesses (soak script, latency probe, canary matrix, install/uninstall
  script) so a human with hardware can execute them.
- **Why safe/reversible:** no fabricated evidence; harnesses are committed;
  running them later does not change product code.
- **Un-block action:** human executes the runbooks on named hardware.

## P5 — Aurum lane deferred (blocks JOE-2307-2314)

- **Blocking gate:** JOE-2314 human decision + JOE-2309 credentials +
  JOE-2294 real-device (per the issue graph and the run contract's Aurum
  lane: non-blocking for the first WhisperKit production frontier).
- **Provisional assumption:** WhisperKit remains the sole production engine;
  Aurum stays experimental. No Aurum CLI/runtime integration is added to the
  Zephyr app; evaluation-schema unification is prepared as a document
  (docs/development/evidence/JOE-2307/prepared-eval-schema.md).
- **Why safe/reversible:** zero product-code coupling to Aurum; the prepared
  schema doc is inert.
- **Un-block action:** human decides JOE-2314, supplies JOE-2309
  credentials/hardware, then the Aurum lane runs from the prepared artifacts.

## P6 — Long-dictation / no-silent-truncation policy (blocks JOE-2251)

- **Blocking gate:** JOE-2251 (human: define the no-silent-truncation
  long-dictation policy).
- **Provisional assumption:** the session/audio pipeline already terminates
  sessions only via explicit control edges or deadline; no silent truncation
  is introduced. The policy's final wording (e.g., max-duration behavior) is
  left to the human.
- **Why safe/reversible:** current behavior is conservative (never truncates
  silently); policy choice only tunes limits.
- **Un-block action:** human drafts JOE-2251; adjust limits accordingly.
