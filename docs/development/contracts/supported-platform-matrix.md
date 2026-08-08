# Supported platform/app matrix, release channels and evidence registry

**Source:** JOE-2245 · milestone M0  
**Status:** SPEC PREPARED — initial production boundary requires **human approval**.

## 1. Supported platform (proposed production boundary)

| Axis | Boundary |
|------|----------|
| macOS | macOS 14.0+ (build/host SDK macOS 26) |
| Architecture | arm64 (Apple Silicon); x86_64 and Intel **unclaimed** until qualified |
| Hardware | Apple Silicon M1–M4 classes |
| Input devices | built-in/Bluetooth microphones |
| Locales | English first release; language wiring per JOE-2254/2289 |
| Engines | WhisperKit 0.18 default; Apple Speech alternative |
| Target apps | see app matrix; anything unlisted is unqualified/unsupported |

Every claim below maps to a row in `docs/development/evidence/evidence-registry.json`; README/docs/UI must not claim anything absent from the registry.

## 2. Minimum app compatibility matrix (seed candidates for M4)

| App | Class | Expected strategy | Status at M0 |
|-----|-------|-------------------|--------------|
| Notes | native text | AX selected-text/value | evidence pending (M4) |
| TextEdit | native text | AX selected-text/value | evidence pending (M4) |
| Terminal | terminal | dedicated paste path | provisional (existing route) |
| Safari | web input | AX/AI selected text | evidence pending |
| Chrome | web input | AX | evidence pending |
| Firefox | web input | AX | evidence pending |
| VS Code | editor/Electron | AX | evidence pending |
| Xcode | editor | AX | evidence pending |
| Slack | Electron | AX | evidence pending |
| secure credentials fields | secure | **copy-only, no auto write** | policy fixed |

Each matrix row requires: bundle ID, app version, macOS, hardware, field/role
class, sensitivity, adapter/strategy, verification method, confidence,
selection/caret/multiline/Unicode behavior, clipboard-restore outcome,
latency distribution and allowed failures. See JOE-2273 for the record schema.

## 3. Release channels

| Channel | Identity | Signing | Update | Gates |
|---------|----------|---------|--------|-------|
| Developer/local | ad-hoc, source-built | ad-hoc | none | unsupported for distribution |
| Preview/beta | explicit preview label/bundle identity | developer ID optional, clearly labeled | preview feed only; explicit opt-in | relaxed, documented |
| Production | exact-candidate artifact set | **Developer ID + notarization mandatory** | signed manifest + verification | full evidence inventory; aborts on any missing prerequisite |

Preview assets can never be offered to production users; production workflow
aborts when secrets/notarization/evidence are missing (JOE-2298).

## 4. Claim-to-evidence registry

Machine-readable index: `docs/development/evidence/evidence-registry.json`.

Registry fields per claim:
`claim, owner, evidence_path, kind (test|report|manual|external),
status (planned|retained|pending), issue`.

## 5. Exact-candidate evidence metadata

Each candidate record retains: source SHA, `Package.resolvedPackage.swift`
hashes, toolchain/Xcode (or CLT + Swift version), macOS runner, entitlements,
signing identity/Team ID, artifact hashes and model versions. Any
candidate-changing fix invalidates affected evidence (JOE-2305).

## 6. Residual-risk rules

- Unsupported/experimental surfaces are clearly marked and excluded from
  release gates unless promoted.
- Human approval records the initial production boundary.

## 7. Validation

Review all current README/privacy/security claims against this matrix (M0/M4);
update docs to match; retain the machine-readable matrix/index in the repo.
