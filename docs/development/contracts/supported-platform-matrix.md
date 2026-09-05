# Supported platform/app matrix, release channels and evidence registry

**Source:** JOE-2245 · milestone M0
**Status:** Initial qualification target approved by the human on 2026-09-05.
**No device/app qualification or production GO is implied.** Candidate-specific
evidence, independent review and final human acceptance remain required.

## 1. Human-selected initial qualification target

| Axis | Boundary |
|------|----------|
| macOS | macOS **15.x**; exact OS build recorded for every qualification run |
| Architecture | arm64 (Apple Silicon); Intel/x86_64 unqualified |
| Hardware | Apple Silicon; named models, RAM and thermal conditions still need measurement, not blanket M1–M4 acceptance |
| Input devices | Exact microphone/input route must be qualified; Bluetooth is not implicitly supported |
| Locales | US English (`en-US`); auto-detection and other languages are experimental/unqualified |
| Engines | Whisper Tiny (pinned WhisperKit 0.18.0) or on-device Apple Speech for `en-US` |
| Target apps | see app matrix; anything unlisted is unqualified/unsupported |

The source deployment minimum remains macOS 14.0; a compiler deployment target
is not the supported production boundary. Current settings retain existing
model/language selections; the default language remains `.auto`, which is
outside this initial qualification target. This target does not silently migrate
settings or promote another combination to qualified support. The selected
ten-minute chunking policy and Control-Option-Space default also require device
qualification. Fn and other combinations remain experimental unless explicitly
promoted with evidence.

The historical `docs/development/evidence/evidence-registry.json` is a claims
index, not proof that a report exists, applies to the current candidate or was
independently accepted. Live Linear criteria and exact-source receipts remain
authoritative; README/docs/UI must distinguish targets from qualified claims.

## 2. Required six-app qualification matrix

| App | Class | Expected strategy | Status at M0 |
|-----|-------|-------------------|--------------|
| Notes | native text | AX selected-text/value | evidence pending (M4) |
| TextEdit | native text | AX selected-text/value | evidence pending (M4) |
| Terminal | terminal | dedicated paste path | evidence pending |
| Safari | web input | AX/clipboard strategy | evidence pending |
| VS Code | editor/Electron | AX | evidence pending |
| Slack | Electron | AX | evidence pending |
| secure/unknown fields in any app | sensitive | **no automatic AX, clipboard mutation, paste or history; explicit review only** | policy fixed; device evidence pending |

Chrome, Firefox, Xcode and other apps are not in the initial six-app boundary.
No successful unit test or existing adapter route promotes them automatically.

Each matrix row requires: bundle ID, app version, macOS, hardware, field/role
class, sensitivity, adapter/strategy, verification method, confidence,
selection/caret/multiline/Unicode behavior, clipboard-restore outcome,
latency distribution and allowed failures. See JOE-2273 for the record schema.

## 3. Release channels

| Channel | Identity | Signing | Update | Gates |
|---------|----------|---------|--------|-------|
| Developer/local | ad-hoc, source-built | ad-hoc | none | unsupported for distribution |
| Preview/beta | identity/channel details pending human decision | not a workaround for production signing policy | explicit isolation required; not implemented/qualified | no inferred waivers |
| Production | exact-candidate artifact set | **Developer ID + notarization mandatory** | signed manifest + verification | full evidence inventory; aborts on any missing prerequisite |

Preview assets cannot be offered as production. Release preflights are currently
manual/read-only and explicitly blocked; no ad-hoc fallback, implicit tagging or
publication. A separately reviewed acceptance verifier is still required
(JOE-2298); credentials alone cannot enable the production path.

## 4. Claim-to-evidence registry

Machine-readable index: `docs/development/evidence/evidence-registry.json`.

Registry fields per claim:
`claim, owner, evidence_path, kind (test|report|manual|external),
status (planned|retained|pending), issue`.

## 5. Exact-candidate evidence metadata

Each candidate record retains: source SHA, separate `Package.resolved` and
`Package.swift` hashes, toolchain/Xcode, macOS runner, entitlements,
signing identity/Team ID, artifact hashes and model versions. Any
candidate-changing fix invalidates affected evidence (JOE-2305).

## 6. Residual-risk rules

- Unsupported/experimental surfaces are clearly marked and excluded from
  release gates unless promoted.
- The human approved the initial qualification target above; final production
  acceptance and exact-candidate GO remain separate.

## 7. Validation

Review all current README/privacy/security claims against this matrix (M0/M4);
update docs to match; retain the machine-readable matrix/index in the repo.
