#!/bin/bash
# JOE-2291: CI gate runner — every gate fails closed; no gate can be skipped
# by path filters. Run from the repo root:
#   ./Scripts/ci_checks.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAILURES=0
REPORT_DIR="${ZF_CI_REPORT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/zephyr-ci.XXXXXX")}"
mkdir -p "$REPORT_DIR"
REPORT_DIR="$(cd "$REPORT_DIR" && pwd)"
export LC_ALL=C

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "GATE FAILED: $*"; FAILURES=$((FAILURES+1)); }
run_logged() {
  local name="$1"
  shift
  local rc=0
  "$@" 2>&1 | tee "$REPORT_DIR/$name.log" || rc=$?
  printf '%s\t%s\n' "$name" "$rc" >> "$REPORT_DIR/commands.tsv"
  return "$rc"
}
finish_report() {
  local rc=$?
  printf 'exit_code=%s\nrecorded_failures=%s\n' "$rc" "$FAILURES" > "$REPORT_DIR/result.txt"
}
trap finish_report EXIT
printf 'Gate reports: %s\n' "$REPORT_DIR"
git rev-parse HEAD > "$REPORT_DIR/source-sha.txt"

# Full gates require Xcode. CLT-only machines can run the Core runner and
# gate regression tests separately; an unavailable XCTest lane is never PASS.
for tool in swift xcrun xcodebuild python3 shellcheck actionlint mkdocs; do
  if ! command -v "$tool" >/dev/null 2>&1; then fail "missing required tool: $tool"; fi
done
if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
if ! run_logged xctest-preflight xcrun --find xctest; then
  fail "full Xcode is required; use swift run ZephyrFlowCoreTests for CLT-only validation"
  exit 1
fi
if ! run_logged python-preflight python3 -c 'import yaml'; then fail "PyYAML is required"; exit 1; fi
run_logged swift-version swift --version
run_logged xcode-version xcodebuild -version

# 1. XCTest target is authoritative. On CI (macos-15 with Xcode) the
#    XCTest files MUST be discovered and executed; `swift test list` must
#    report all existing suites. The CLT suite is separate Core evidence,
#    not a substitute for executing XCTest or production-adapter tests.
step "1/9 XCTest (swift test)"
if ! run_logged xctest swift test; then fail "swift test"; fi
if run_logged xctest-discovery swift test list; then
  for suite in M0ContractTests ProductionBlockerTests FlowProcessorTests ModelsTests; do
    if ! grep -Eq "^ZephyrFlowTests[.]$suite/test" "$REPORT_DIR/xctest-discovery.log"; then
      fail "XCTest suite not discovered: $suite"
    fi
    if ! grep -Eq "Test Suite '$suite' passed" "$REPORT_DIR/xctest.log"; then
      fail "XCTest suite execution not confirmed: $suite"
    fi
  done
else
  fail "XCTest discovery command failed"
fi

# 2. CLT runner (Core-only deterministic evidence, no Xcode required).
step "2/9 CLT Core runner"
if ! run_logged core swift run ZephyrFlowCoreTests; then fail "swift run ZephyrFlowCoreTests"; fi

# 3. Strict concurrency at the strongest setting available in Swift 5 mode
#    (-strict-concurrency=complete). Note: the package is swift-tools 5.10, so
#    this is NOT Swift 6 language mode; see docs/development/ci/sanitizers.md
#    for the Swift 6 language-mode follow-up. NEW warnings fail (pinned baseline).
step "3/9 strict concurrency (complete, Swift 5 mode) vs baseline"
# Clean build so every warning is emitted (a cached build would emit none and
# silently pass); the baseline was produced the same way. Review R8.1: the
# BUILD's exit status is authoritative — a compile failure must FAIL the gate,
# never be swallowed by `|| true` (the old pipe masked build errors as a
# zero-warning pass).
if ! run_logged clean swift package clean; then fail "clean before strict build"; fi
if ! run_logged strict-build swift build --build-tests -Xswiftc -strict-concurrency=complete; then
  fail "strict-concurrency build failed"
fi
# Compare primary occurrences using this checkout's actual root, not a
# hard-coded directory name. Reductions are allowed; new files, warnings or
# increased occurrence counts fail. Baseline expansion needs separate review.
if ! run_logged strict-warnings python3 Scripts/ci/check_warnings.py \
    --root "$ROOT" --build-log "$REPORT_DIR/strict-build.log" \
    --baseline docs/development/ci/strict-concurrency-warnings-baseline.txt \
    --output "$REPORT_DIR/warnings.txt"; then
  fail "new or unparseable strict-concurrency warnings"
fi

# 4. Formatting lint (warnings are failures) + string-catalog completeness.
step "4/9 swift-format lint + string catalog scan"
if ! run_logged format swift format lint --strict --recursive Sources Tests; then
  fail "swift-format lint"
fi
if ! run_logged strings python3 Scripts/string_scan.py; then
  fail "string catalog scan"
fi

# 5. Shell, CI workflow semantics and YAML syntax lint.
step "5/9 shell + Actions + YAML lint"
if ! run_logged actions actionlint .github/workflows/ci.yml; then
  fail "CI workflow Actions validation"
fi
# Review R8.1: shellcheck covers ALL Scripts subdirectories (recursive),
# not just Scripts/*.sh, and its absence is a FAILURE (not a silent skip).
# Review NIT-5: recursive script discovery via find (globstar-independent;
# portable to macOS bash 3.2 — no mapfile).
# Review NIT (round 4): -print0 + read -d '' so paths with spaces/newlines
# are handled correctly (not split on IFS).
FOUND_SH=0
while IFS= read -r -d '' sh; do
  FOUND_SH=$((FOUND_SH+1))
  run_logged "bash-$FOUND_SH" bash -n "$sh" || fail "bash -n $sh"
done < <(find Scripts -name '*.sh' -print0)
if [[ "$FOUND_SH" -eq 0 ]]; then
  fail "no shell scripts found under Scripts/"
fi
if command -v shellcheck >/dev/null 2>&1; then
  SH_INDEX=0
  while IFS= read -r -d '' sh; do
    # --severity=warning: real defects (warnings/errors) fail the gate;
    # info-level notes (e.g. SC1091 follow-sourcing, SC2086 quoting) do not.
    SH_INDEX=$((SH_INDEX+1))
    run_logged "shellcheck-$SH_INDEX" shellcheck --severity=warning -x "$sh" || fail "shellcheck $sh"
  done < <(find Scripts -name '*.sh' -print0)
else
  fail "shellcheck not installed (required by the gate)"
fi
# Review R8.1: YAML validation must not be silently omitted when PyYAML is
# missing — require it.
if python3 -c 'import yaml' 2>/dev/null; then
  for yml in .github/workflows/*.yml; do
    run_logged "yaml-$(basename "$yml")" python3 -c \
      'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))' "$yml" || fail "YAML $yml"
  done
else
  fail "PyYAML not installed (required by the gate)"
fi
if ! run_logged gate-regressions python3 -m unittest discover -s Tests/CI -p 'test_*.py'; then
  fail "gate regression tests"
fi

# 6. Docs strict build + version gate.
step "6/9 docs strict + version gate"
if command -v mkdocs >/dev/null 2>&1; then
  run_logged docs mkdocs build --strict --site-dir "$REPORT_DIR/site" || fail "mkdocs --strict"
else
  fail "mkdocs is required"
fi
v="$(tr -d '[:space:]' < VERSION)"
grep -q "static let version = \"$v\"" Sources/ZephyrFlow/Utilities/Constants.swift || fail "VERSION/Constants drift"
grep -q "<string>$v</string>" Resources/Info.plist || fail "VERSION/Info.plist drift"
grep -q "^## \[$v\]" CHANGELOG.md || fail "VERSION/CHANGELOG drift"

# Gate 7 runs last, so coverage and sanitizer generation is checked too.

# 8. Trust-boundary coverage (ZephyrFlowCore only — cannot be inflated by
#    untested code elsewhere; adding untested Core code LOWERS the %).
step "8/9 trust-boundary coverage (ZephyrFlowCore)"
COV_TMP="$(mktemp -d "$REPORT_DIR/coverage.XXXXXX")"
BIN=""
if swift build --show-bin-path > "$REPORT_DIR/bin-path.txt" 2> "$REPORT_DIR/bin-path-error.log"; then
  BIN="$(cat "$REPORT_DIR/bin-path.txt")"
else
  fail "cannot resolve Swift build products"
fi
# `swift test --enable-code-coverage` builds every target instrumented;
# we then run the CLT suite (the full deterministic check set) with a
# captured profile and merge it with the XCTest profile.
if [[ -n "$BIN" ]] && run_logged coverage-tests swift test --enable-code-coverage \
   && run_logged coverage-core env LLVM_PROFILE_FILE="$COV_TMP/clt.profraw" "$BIN/ZephyrFlowCoreTests"; then
  PROFILES=()
  [[ -f "$COV_TMP/clt.profraw" ]] && PROFILES+=("$COV_TMP/clt.profraw")
  if [[ -d "$BIN/codecov" ]]; then
    while IFS= read -r -d '' profile; do PROFILES+=("$profile"); done \
      < <(find "$BIN/codecov" -name '*.profraw' -print0)
  fi
  CORE_SOURCES=()
  while IFS= read -r -d '' source; do CORE_SOURCES+=("$source"); done \
    < <(find "$ROOT/Sources/ZephyrFlowCore" -name '*.swift' -print0)
  if [[ -f "$COV_TMP/clt.profraw" && "${#PROFILES[@]}" -gt 1 && "${#CORE_SOURCES[@]}" -gt 0 ]] \
     && run_logged coverage-merge xcrun llvm-profdata merge -o "$COV_TMP/core.profdata" "${PROFILES[@]}" \
     && run_logged coverage-report xcrun llvm-cov report "$BIN/ZephyrFlowCoreTests" \
        -instr-profile="$COV_TMP/core.profdata" "${CORE_SOURCES[@]}"; then
    REGION="$(awk '/^TOTAL[[:space:]]/{print $4}' "$REPORT_DIR/coverage-report.log" | tr -d '%')"
    LINE="$(awk '/^TOTAL[[:space:]]/{print $10}' "$REPORT_DIR/coverage-report.log" | tr -d '%')"
    echo "ZephyrFlowCore coverage: line=${LINE}% region=${REGION}% (region coverage is not branch coverage or app coverage)"
    if ! awk -v x="$LINE" 'BEGIN{exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x>=70 && x<=100)}'; then
      fail "coverage line missing/invalid or < 70% (got ${LINE}%)"
    fi
    if ! awk -v x="$REGION" 'BEGIN{exit !(x ~ /^[0-9]+([.][0-9]+)?$/ && x>=70 && x<=100)}'; then
      fail "coverage region missing/invalid or < 70% (got ${REGION}%)"
    fi
  else
    fail "coverage report"
  fi
else
  fail "coverage measurement"
fi
# Retain profiles and the complete report for success and failure inspection.

# 9. ASan and simulated control/recovery (not real app kill/relaunch).
step "9/9 ASan / simulated control and recovery"
# ASan on exercised XCTest paths. No TSan result is established by this lane;
# compile-time concurrency checks and Core stress are not runtime race proof.
if run_logged asan swift test --sanitize=address; then
  echo "ASan: clean"
else
  fail "ASan lane"
fi

# Core simulations are useful separate evidence, not native resource or
# signed-app crash/relaunch qualification. Preserve the entire process status.
echo "simulated control + recovery lane (CLT stress suite)"
if [[ -n "$BIN" && -x "$BIN/ZephyrFlowCoreTests" ]]; then
  if run_logged stress "$BIN/ZephyrFlowCoreTests"; then
    for issue in 2292 2293; do
      if ! grep -q "✓ $issue" "$REPORT_DIR/stress.log"; then fail "missing Core stress checks for $issue"; fi
    done
  else
    fail "rapid-control/crash-recovery lane"
  fi
else
  # Review NIT-6: a missing stress binary means the rapid-control/crash
  # lane did not run — fail closed (do not report the lane as green).
  fail "rapid-control/crash-recovery lane: CLT stress binary not found"
fi

step "7/9 final drift check (tracked, staged and untracked files)"
if ! git diff --exit-code --quiet || ! git diff --cached --exit-code --quiet; then
  fail "tracked or staged drift after gates"
fi
git ls-files --others --exclude-standard > "$REPORT_DIR/untracked.txt"
if [[ -s "$REPORT_DIR/untracked.txt" ]]; then fail "untracked generated drift after gates"; fi
git status --porcelain > "$REPORT_DIR/git-status.txt"

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "ci_checks: $FAILURES gate(s) FAILED — refusing merge."
  exit 1
fi
echo "ci_checks: ALL GATES PASSED."
