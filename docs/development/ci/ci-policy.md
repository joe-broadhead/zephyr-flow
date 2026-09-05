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
    serialized AX-handle ownership without AX messages. The boundary suite
    also tests checked process-start
    conversion and read-only libproc identity queries of its own XCTest process.
    Neither suite opens a
   microphone or personal store, requests permissions, or writes to another app.
   `ProductionEngineTests` exercises the app's WhisperKit engine with a
   controlled runtime factory and the runtime's exclusive-call owner with a
   controlled backend: stale/cancelled loads, active-model isolation and
   cancellation that does not stop native work. No model weights are loaded;
   this does not verify WhisperKit inference or tokenizer networking.
   `ProductionOfflineTokenizerTests` parses synthetic local vocabularies and
   rejects missing/corrupt/mismatched artifacts. It also runs in a separate
   network-denied process via `Scripts/ci/offline_tokenizer_tests.sh`, with a
   loopback permission-denial probe and required suite-execution evidence.
   This bounds the exercised loader paths; it is not a complete app privacy
   canary or real-model inference qualification. The direct Tokenizers/Hub
    APIs use the already-resolved swift-transformers **1.1.9** revision.
    `ProductionPreparationTests` exercises the application preparation
    coordinator using injected artifact/acquisition closures and held engine
    actors: consent, verification vs loaded readiness, explicit Apple loading,
    supersession, retry, quarantine and cancellation before native completion.
    Capability-failure, fresh/cached language preflight, disk-headroom and
    onboarding consent-versus-loaded-state checks use injected capability data.
    Actual Apple Speech checks authorization, the exact requested locale and
    Local Only support before candidate publication and again before capture;
    permission prompts remain explicit Setup actions, not engine-load effects.
    The controller now consumes that coordinator and the environment's engine
    factories; these tests do not instantiate the full UI controller or perform
    real acquisition, Speech authorization, capture, or inference.
    `ProductionAcquisitionTests` uses the production filesystem with private
    temporary roots, tiny synthetic components and held download closures. It
    checks cancellation propagation, retained singleflight ownership, retry,
    consent on joining requests, and generation-bound progress. It does not
    exercise a real transport or qualify pinned model provenance.
    `ProductionPasteboardTests` uses unique named AppKit pasteboards with
    synthetic type/data representations (never the general pasteboard). It
    exercises shared failure/success restoration, empty/multi-item round trips,
    duplicate cleanup, ownership changes and snapshot rejection. Posting state
    is simulated: no keyboard events or target-app writes occur. NSPasteboard
    has no cross-process conditional-write primitive; these checks do not prove
    atomic exclusion, provider IPC deadlines, provider allocation bounds, crash
    recovery or six-app insertion qualification.
    `ProductionHistoryTests` injects synthetic key providers and temporary
    history stores into the shared preparation service and actual history view
    model. It checks disabled-history non-access, key-before-load ordering,
    cancellation/deadline waiters, retained initialization ownership, controlled
    read/key failures and retry. No personal history or Keychain item is read or
    changed; these tests do not qualify reboot/login Keychain availability or
    secure-session behavior across the full controller.
    Flow release-gate tests reject missing/zero/malformed style statistics.
    **The inherited Flow corpus has no Raw cases despite the policy's Raw
    budget. Its qualification result is INCOMPLETE, not PASS.** The Core runner
    asserts that rejection as an evaluator regression; passing Core/XCTest is
    not a passing Flow release gate. The corpus and numeric budgets are not
    changed by this fix. Reviewed corpus completion and independently verified
    policy/candidate provenance remain separate acceptance work.
    `FlowDeadlineTests` holds synthetic backend/configuration actors across
    caller deadlines and cancellation. Flow's typed request deadline covers
    routing, configuration, regex and enhanced work; callers do not join a
    noncooperative child task. One outstanding worker remains owned until its
    actual return; requests while busy receive an explicit verbatim fallback
    rather than queue more native work. Deadline fallback preserves the exact
    input without token scanning (the diagnostic span count is not a census).
    OS scheduling is not a hard-real-time guarantee, and a stuck worker can
    retain one request until it finishes. No semantic-quality or device-latency
    qualification is inferred from these controlled tests.
    `ProductionSettingsTests` injects in-memory settings persistence and fake
    ServiceManagement operations into the actual settings/login services. It
    checks publish-after-acknowledgment, encoding/write rejection, pending
    admission, authoritative verification, failed/approval states and external
    compensation after failed settings persistence. It never changes real
    preferences or login registration. UserDefaults synchronization/read-back
    is not fsync or a cross-process transaction; power-loss/relaunch durability,
    real ServiceManagement approval and login behavior remain device work.
    `ProductionFnPreferenceTests` uses only an injected in-memory journal and
    synthetic preference values. It checks typed property-list round trips,
    journal-before-mutation, pending-apply crash-state simulation, read-back
    failure, explicit retry, unknown/legacy records and preservation of a
    later unrelated value. No global Fn preference, event tap, login item or
    TCC permission is changed. Legacy present-value journals cannot reconstruct
    an exact value and remain blocked rather than guessing/removing a key.
    CFPreferences has no compare-and-swap and synchronization is not an fsync
    guarantee; real crash/power-loss and supported-macOS qualification remain
    required. Native tap startup is checked separately from thread creation;
    this is not full hotkey native-lifecycle or hung-thread qualification.
    Native sensitivity-reader mapping tests inject role/subrole/enabled replies
    into the same helper used by target capture/revalidation, AX-write preflight
    and paste/copy checks. Secure subrole evidence confines an ordinary role;
    optional-attribute absence is distinguished from IPC/type/read failure,
    which stays unknown. These tests issue no AX messages or field reads. The
    synchronous reader is not a bounded IPC/atomic-focus guarantee; live hung
    targets, same-app field races and the six-app matrix remain unqualified.
    `ProductionAdmissionTests` runs the actual session actor's admission path
    with production stages and injected target/history/engine dependencies.
    Captured sensitivity precedes history initialization; secure/unknown/missing
    target or disabled history skips that dependency. Preparation starts no
    recording, reuses one snapshot, and rejects cancellation/key-storage failure.
    The controller awaits this path before showing its panel, so stage startup
    does not recapture the app's own UI. These are not whole-controller event,
    actual AX focus, TCC, microphone, continuously changing sensitivity or
    device qualification tests. Later validation still applies the restrictive
    session history/insertion policy.
    `AxBoundedRunnerTests` uses held synchronous closures and injected scheduling,
    not actual AX IPC. It checks cancellation before/after worker admission,
    deadlines rechecked at admission, retained singleflight after timeout,
    rejection of retries, and late-result isolation. Infinite-loop fixtures are
    not used. The shared production AX-write lane remains occupied until native
    completion; cancellation/timeout is not proof a write did not apply. This
    does not bound preflight/capture AX IPC, make scheduling hard real time,
    prove native memory bounds, or provide atomic target/clipboard exclusion.
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
