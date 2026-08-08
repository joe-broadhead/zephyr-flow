# Human Gates — exact runbooks (run 20260808T103416Z)

Every issue below is held for human judgment, real-device evidence or
external credentials. Nothing here is agent self-approved. Prepared artifacts
are committed; the remaining action is exactly what a human must do.

Repo: `agent/zephyr-production-run-20260808T103416Z` (head listed in
final-report.md). All paths relative to the repo root. The app for manual
steps: `./Scripts/build_app.sh debug && open Dist/ZephyrFlow.app`.

---

## Human decisions (no hardware required)

### JOE-2251 — no-silent-truncation long-dictation policy
1. Review current behavior: sessions terminate only on explicit control
   edges (press/release, cancel) or the bounded deadline; there is no silent
   truncation path (JOE-2246/2247/2277).
2. Decide: (a) keep unbounded-with-explicit-stop, (b) add a configurable
   max-duration, (c) add a max-duration with audible warning.
3. Comment the decision on JOE-2251; adjust `SessionSettingsSnapshot`
   limits accordingly if (b)/(c).

### JOE-2285 — conventional configurable production hotkey vs Fn/Globe
1. Try the built app with Fn/Globe (default) and with Control+Space /
   Right Option (already selectable in Settings).
2. Decide the default. If a conventional default is chosen, it is already
   implementable via `HotkeyConfig(keyCode:modifiers:)` (JOE-2287 engine
   serves standard chords); decide whether the AppleFnUsageType experimental
   opt-in (JOE-2286, default off) stays.
3. Comment the decision; the run's provisional assumption P1 is recorded in
   provisional-decisions.md.

### JOE-2298 — split preview and production release channels
1. Decide channel model (e.g., preview = ad-hoc debug builds, production =
   Developer-ID-signed + notarized with exact-tag checkout).
2. If production: supply Developer ID credentials (see JOE-2299) and enable
   the prepared `Scripts/release/supply-chain/` manifests (JOE-2300-2304
   deferred under P2).
3. Comment the decision.

### JOE-2305 — freeze one exact candidate + run the complete production audit
1. Freeze a commit on `agent/zephyr-production-run-20260808T103416Z`
   (head in final-report.md).
2. Run `bash Scripts/ci_checks.sh` on the frozen commit (all 9 gates; CI
   macos-15 executes XCTest, gate 1).
3. Execute the real-device runbooks below for the frozen candidate.
4. Record GO/NO-GO with evidence on JOE-2305.

### JOE-2306 — verify post-publication assets, update path, support readiness
After JOE-2305 GO and a publication: verify the update manifest (JOE-2302
prepared), launch-at-login (JOE-2290), support bundle (JOE-2265) on a clean
Mac. Record evidence on JOE-2306.

### JOE-2314 — Aurum: defer / retain experimental / ship optional
1. Read prepared-eval-schema.md (JOE-2307) and the Aurum lane disposition
   (P5 in provisional-decisions.md).
2. Decide. If shipping optional: supply JOE-2309 credentials/hardware and
   run the Aurum lane from its prepared artifacts.
3. Comment the decision on JOE-2314.

---

## Real-device qualification (hardware required)

### JOE-2257 — rapid-control, late-callback, engine-lifecycle stability
Commands:
```bash
# 10 min of randomized rapid press/release/cancel against the app
./Scripts/qual/rapid_control_soak.sh --minutes 10 --app Dist/ZephyrFlow.app
# expectations: exactly-one terminal per session; no duplicate sessions; no crash
```
Report: crash logs, session counts, soak duration, machine + macOS version.

### JOE-2273 — supported-app insertion matrix
```bash
./Scripts/qual/insertion_matrix.sh --apps 'Notes,TextEdit,Mail,Safari,Slack,Terminal' --rounds 25
```
Expectations per JOE-2268/2269/2270: validated insertion with rollback on
target change; record per-app pass/fail + AX trust state.

### JOE-2274 — focus switches, secure fields, hung AX targets, clipboard
```bash
./Scripts/qual/focus_stress.sh --rounds 40
./Scripts/qual/secure_field_probe.sh   # 1Password/Keychain-style secure fields
```
Expectations: no insertion into secure fields (fail-closed, JOE-2259/2268);
hung AX targets bounded (TargetRestoreMonitor); pasteboard restored exactly
on failure (JOE-2260).

### JOE-2288 — VoiceOver, keyboard, reduced-motion, contrast, pointer
Manual: enable VoiceOver + Full Keyboard Access + Reduce Motion; exercise
Settings/Onboarding/Panel; run `./Scripts/qual/accessibility_probe.sh`.
Report per accessibility feature.

### JOE-2294 — real-speech observatory (WER/CER, silence false positives)
```bash
./Scripts/qual/speech_observatory.sh --utterances ./corpus --engine whisper --rounds 50
```
Produces WER/CER + silence-false-positive report (no transcript bodies in
logs — only metrics). Machine: named hardware + macOS + toolchain.

### JOE-2295 — named-hardware latency/memory/energy/thermal/battery
```bash
./Scripts/qual/hardware_profile.sh --minutes 15 --app Dist/ZephyrFlow.app
```
Records hold-to-first-partial latency, RSS peak, energy impact, thermal
state, battery drain. Report per named machine.

### JOE-2296 — 1,000-session soak + maximum-duration stability
```bash
./Scripts/qual/soak_1000.sh --sessions 1000
```
Expectations: no leak growth (JOE-2292 harness invariants), no session
cross-talk, bounded resource usage.

### JOE-2303 — fresh-Mac install/upgrade/launch-at-login/uninstall
Manual on a clean Mac: install Dist/ZephyrFlow.app, launch, upgrade over
previous build, verify launch-at-login (JOE-2290), uninstall leaves no
preferences/history residue. Record steps + screenshots.

### JOE-2312 — Aurum FFI lifecycle, Metal teardown, cancellation
Requires JOE-2314 decision + JOE-2309 artifacts; runbook in the Aurum lane
(prepared-eval-schema.md + aurum-qual.md under docs/development/evidence/).

### JOE-2313 — preregistered Aurum vs WhisperKit production bake-off
Requires JOE-2312; protocol + scoring sheet prepared under
docs/development/evidence/JOE-2313/.

---

## Credential gates (external)

### JOE-2299 — Developer ID signing, hardened runtime, notarization
1. Supply a Developer ID Application certificate in the macOS keychain
   (name must match `Scripts/release/notarize.sh` config).
2. Run `./Scripts/release/notarize.sh --dry-run` (prepared) then the real
   flow: `codesign --options runtime`, `notarytool submit`, staple.
3. Record notarization ticket + Gatekeeper clean-install verification.

### JOE-2309 — Aurum STT-only macOS XCFramework/native SDK publication
Requires JOE-2298 channel decision + Apple credentials; run the Aurum
release lane from prepared scripts (see Aurum lane docs).

---

## Evidence-only gate

### JOE-2297 — end-to-end privacy canary matrix
Blocked by JOE-2274 (real-device). Prepared canary harness:
```bash
./Scripts/qual/privacy_canary.sh --rounds 20
```
Verifies per data flow (audio, history, model, pasteboard, telemetry):
Local-Only keeps network off; no transcript bodies in logs (ZFLog lengths
only); history plaintext only when saveHistory is on (JOE-2262 encryption
otherwise). Record per-flow pass/fail.
