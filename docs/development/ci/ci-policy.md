# CI Policy (JOE-2291)

Every pull request must pass every gate below. No gate can be skipped by path
filters; all gates run on every PR and every push to the integration branch.
A gate that fails blocks merge. Coverage is measured over the **trust
boundary only** (ZephyrFlowCore) so it cannot be inflated by adding untested
code elsewhere — adding untested Core code lowers the measured percentage.

## Gates (in order, all required)

1. **XCTest** — `swift test` is the authoritative test target and must pass.
   The custom CLT runner (`swift run ZephyrFlowCoreTests`) is retained for its
   distinct purpose (no Xcode required) and is kept in parity: both run in CI.
2. **Swift 6 strict concurrency** — the app and tests compile with
   `-Xswiftc -strict-concurrency=complete` (strongest supported setting).
   NEW warnings fail CI against the pinned baseline
   `docs/development/ci/strict-concurrency-warnings-baseline.txt`
   (93 normalized entries at baseline; shrink over time — the ZephyrFlowCore
   trust boundary is already clean). Regeneration instructions are in the
   baseline header; regenerating requires a deliberate, reviewed commit.
3. **Formatting** — `swift format lint --strict --recursive Sources Tests`
   with warnings treated as failures (config: `.swift-format`).
4. **Lint** — `bash -n` + `shellcheck` on `Scripts/*.sh`; YAML syntax check
   on `.github/workflows/*.yml`; markdown is validated by the docs strict
   build (Material for MkDocs).
5. **Docs** — `mkdocs build --strict` (broken links, warnings and missing
   pages fail).
6. **Version/manifest/link checks** — VERSION must equal
   `Constants.version`, `Resources/Info.plist` and the `CHANGELOG.md`
   `## [x.y.z]` heading.
7. **Drift** — after all gates, `git diff --exit-code` must be clean: no
   generated artifacts may be left dirty by the build/test/docs steps.
8. **Trust-boundary coverage** — instrumented CLT run + `llvm-cov` restricted
   to ZephyrFlowCore: line ≥ 70%, branch ≥ 75% (measured baseline
   74.35% / 82.40%). Thresholds are policy; the required module set
   (`ZephyrFlowCore`) is fixed by policy and cannot be bypassed.

## Tool versions and reproducibility

- Toolchain: Swift 6.x on `macos-15` (GitHub-hosted), matching the local
  `swift --version` used for the baseline.
- `Package.resolved` pins WhisperKit; `docs/requirements.txt` pins docs deps.
- CI cache keys include the package lockfile hash; no floating dependencies.
- A green baseline report is retained at
  `docs/development/ci/coverage-baseline-report.txt`.

## Privacy in CI output

- Test/coverage artifacts contain **no transcript bodies, audio, keys or
  private fixture content** — Core tests assert lengths/equality only and
  fixtures are synthetic. Artifacts are published for failed AND successful
  runs (build log, coverage report) with `actions/upload-artifact`.
