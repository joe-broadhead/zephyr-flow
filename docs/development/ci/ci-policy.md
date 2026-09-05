# CI Policy (JOE-2291)

Every pull request must pass every gate below before acceptance. The CI Gates
job has no path filters and returns failure when a required tool or lane fails.
**Repository enforcement is separate:** the job must also be configured as a
required status check. The existing required checks do not yet include Gates;
changing branch protection requires explicit approval. A passing job is not a
production release approval.

## Gates (all required; drift runs last)

1. **XCTest** — `swift test` is the authoritative test target and must pass;
   `swift test list` must succeed and discover each existing suite. Execution
   logs must confirm those suites passed. Missing XCTest cannot compile to an
   empty test target. Most suites test Core contracts. `ProductionAudioTests`
   exercises in-memory native PCM snapshot/conversion adapters, while
   `ProductionBoundaryTests` exercises settings/permission reads with injected
   sources and detached callers, speech callback value/error snapshots, and
   serialized AX-handle ownership without AX messages. Neither suite opens a
   microphone or personal store, requests permissions, or writes to another app.
   These bounded checks do **not** establish
   full coordinator, live capture, insertion or device qualification.
2. **Core runner** — `swift run ZephyrFlowCoreTests` supplies deterministic
   Core evidence on CI and on CommandLineTools-only machines. It is neither
   a replacement for XCTest nor evidence of equivalent production coverage.
3. **Strict concurrency** — after a successful clean, the app and tests build
   with `swift build --build-tests -Xswiftc -strict-concurrency=complete` in
   **Swift 5 language mode**. `Scripts/ci/check_warnings.py` compares primary
   diagnostics against `strict-concurrency-warnings-baseline.txt`, retaining
   repository-relative file identity, diagnostic and occurrence count.
   New/increased warnings and unrecognized warning formats fail; reductions
   are allowed. Baseline expansion requires a separate reviewed change.
   `warning-locations.json` additionally groups primary emissions by diagnostic
   and line/column within that build, retaining unlocated warnings. This is
   diagnostic evidence, **not a deduplicated replacement budget**. Coordinates
   are not stable identities across edits; compiler changes can alter IDs,
   messages and emission counts. The historical baseline does not identify its
   exact compiler/build settings. Such mismatches require same-toolchain source
   review, not automatic baseline regeneration or warning suppression.
4. **Formatting and strings** — strict recursive Swift formatting plus
   `Scripts/string_scan.py`. The string scan resolves known catalogue
   references; it is not complete localization or accessibility acceptance.
   The multiline-string reflow option retains the `never` policy using the
   Swift 6.1-compatible object encoding. A small decoder-shape regression and
   an installed-formatter smoke test check compatibility separately; the former
   does not execute an older formatter. Strict recursive lint is still required.
5. **Lint and gate regressions** — recursive Bash/ShellCheck checks,
   `actionlint .github/workflows/ci.yml` (including Actions context rules),
   workflow YAML syntax, and `python3 -m unittest discover -s Tests/CI -p 'test_*.py'`.
   The isolated tool-double tests exercise error handling without running an
   app or compiler. They are not XCTest, sanitizer or coverage measurements.
6. **Docs and version** — required `mkdocs build --strict`, writing the site
   outside the checkout. VERSION must match Constants, Info.plist and the
   changelog heading. Navigation completeness is a separate review concern.
7. **Drift** — after coverage/sanitizers, check tracked, staged and untracked
   non-ignored changes. Run the full gate on a clean candidate checkout;
   do not discard local work to make this check pass.
8. **Core coverage** — instrumented XCTest and CLT profiles are merged, and
   `llvm-cov` reports the Core executable's mapped ZephyrFlowCore sources.
   Both profiles and a valid report are required. Existing thresholds remain
   **line ≥ 70%, region ≥ 70%**. Missing/invalid percentages fail.
   Region coverage is **not branch coverage**; this report does not measure
   app-adapter coverage or prove every trust-boundary branch is exercised.
   The checked-in baseline is historical, not a new candidate result.
9. **ASan and simulated control/recovery** — run XCTest with Address Sanitizer
   and the deterministic Core stress checks. Preserve full process exit codes,
   not just selected success markers. Real native cleanup and signed-app
   kill/relaunch qualification remain separate.

## Running locally and retaining evidence

On a machine with full Xcode selected and required tools installed:

```bash
python3 -m venv "$TMPDIR/zephyr-gate-venv"
"$TMPDIR/zephyr-gate-venv/bin/python" -m pip install -r Scripts/ci/requirements.txt
PATH="$TMPDIR/zephyr-gate-venv/bin:$PATH" bash Scripts/ci_checks.sh
```

ShellCheck and actionlint must also be installed. Without full Xcode, use the Core runner,
gate regression tests, formatting and docs commands separately; the full gate
fails its preflight rather than claiming skipped lanes passed.

`ZF_CI_REPORT_DIR` selects an **external** report directory; otherwise a unique
temporary directory is created and printed. Retained output includes source
SHA, tool versions, full command logs, `commands.tsv` (command name and exit
code), `result.txt` (overall exit and failure count), profiles and coverage.
CI uploads reports even after setup/gate failure. Cancellation or runner loss
may prevent artifact upload and must not be interpreted as completed evidence.

## Tool versions and reproducibility

- Both macOS jobs select `/Applications/Xcode_16.4.app/Contents/Developer` and
  require Xcode **16.4 / 16F6** before building; a missing or mismatched toolchain
  fails rather than falling back to the runner default. CI records actual
  macOS/Xcode/Swift/formatter versions. This selection does not retroactively
  qualify the historical warning baseline or establish Swift 6 language-mode
  acceptance. `macos-15`, Python 3.12 patch and Homebrew ShellCheck/actionlint
  remain unpinned; this is not a fully reproducible runner image.
- Python gate packages are installed in a temporary virtual environment, never
  into Homebrew/system Python. Setup errors are not suppressed. Direct versions
  in `Scripts/ci/requirements.txt` constrain the shared docs requirements;
  transitive versions are recorded with `pip freeze`, not fully hash-locked.
- `Package.resolved` remains unchanged. The gate's final drift check rejects
  tracked lockfile changes. Full reproducibility and broader coverage policy
  remain acceptance work; do not relabel historical reports as current proof.

## Privacy in CI output

- Use synthetic fixtures only. Do not log real transcript bodies, audio,
  keys, private fixture payloads or credentials. Full failure logs are retained,
  so assertion messages must also respect this restriction. CI does not load
  personal app state or require signing credentials for these gates.
