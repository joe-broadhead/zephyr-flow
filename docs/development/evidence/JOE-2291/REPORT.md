# JOE-2291 — PR CI gates: XCTest authoritative, strict concurrency, lint, format, docs, version, drift, coverage

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Deliverables

- `Scripts/ci_checks.sh` — fail-closed gate runner (all 8 gates, no path
  filters): (1) `swift test` (XCTest authoritative), (2) `swift run
  ZephyrFlowCoreTests` (CLT parity — distinct purpose, no Xcode), (3)
  `swift package clean && swift build -Xswiftc -strict-concurrency=complete`
  with NEW-warning failure vs pinned baseline, (4) `swift format lint
  --strict` (warnings are failures; whole Sources+Tests tree normalized to
  `.swift-format` config), (5) shellcheck + `bash -n` + YAML syntax, (6)
  `mkdocs build --strict` + VERSION/Constants/Info.plist/CHANGELOG sync, (7)
  drift check `git diff --exit-code` (no generated artifacts left dirty), (8)
  trust-boundary coverage (ZephyrFlowCore only) via instrumented CLT run:
  line ≥ 70%, region ≥ 70%.
- `.github/workflows/ci.yml` — new `gates` job (macos-15, 60 min) running
  ci_checks.sh; artifacts uploaded for success AND failure; no path filters.
- `docs/development/ci/ci-policy.md` — gate definitions, toolchain pinning,
  cache-key reproducibility, privacy-in-CI-output guarantees, coverage
  policy (required module set fixed; cannot be bypassed).
- `docs/development/ci/strict-concurrency-warnings-baseline.txt` — 93 pinned
  normalized warnings with remediation plan + regeneration instructions.
- `docs/development/ci/coverage-baseline-report.txt` — green baseline report.
- Hygiene fixes surfaced by the gates: FakeSleeper async-safe locking,
  ActorHistoryRepository try?, FlowProcessor unused var, AudioChannel naming,
  shellcheck SC2034 in capture_screenshots.sh, trailing-closure lint fixes.

## Acceptance criteria

- PR cannot merge when XCTest/strict concurrency/formatting/lint/docs/
  version/coverage gates fail — ci_checks.sh exits non-zero on any failure;
  gates job required.
- Current XCTest files actually executed and reported — swift test runs
  Tests/ZephyrFlowTests (FlowProcessorTests, M0ContractTests).
- New concurrency warnings fail CI — pinned-baseline comm check (proven by
  removing one baseline entry → gate fails).
- Coverage policy names required modules/branches; cannot be bypassed by
  untested code outside the measured set — coverage measured ONLY over
  ZephyrFlowCore (adding untested Core code lowers the %).
- CI output contains no private fixture content/secrets — Core tests assert
  lengths/equality only; fixtures synthetic; policy documents this.

## Fail-closed proof (representative probes, reverted)

1. VERSION=9.9.9 → version drift gates fail (Constants/Info.plist/CHANGELOG).
2. Trailing whitespace in a Core file → swift-format lint gate fails.
3. One baseline entry removed → "new strict-concurrency warnings" gate fails.
4. Drift gate catches any dirty tree after gates (observed during work).

## Green baseline

`bash Scripts/ci_checks.sh` → ALL GATES PASSED (XCTest 0, CLT 0, strict
warnings == baseline, lint 0, shellcheck 0, YAML ok, docs strict 0, version
sync ok, drift clean, ZephyrFlowCore line=82.40% region=74.35%).
