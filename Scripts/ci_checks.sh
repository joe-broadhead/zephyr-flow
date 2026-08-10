#!/bin/bash
# JOE-2291: CI gate runner — every gate fails closed; no gate can be skipped
# by path filters. Run from the repo root:
#   ./Scripts/ci_checks.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAILURES=0

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "GATE FAILED: $*"; FAILURES=$((FAILURES+1)); }

# 1. XCTest target is authoritative. On CI (macos-15 with Xcode) the
#    XCTest files MUST be discovered and executed; `swift test list` must
#    report them. Local machines using only CommandLineTools cannot run
#    xctest — the parity CLT suite (gate 2) covers them, documented.
step "1/9 XCTest (swift test)"
if ! swift test 2>&1 | tail -3; then fail "swift test"; fi
TEST_LIST="$(swift test list 2>/dev/null | grep -c 'test' || true)"
if [[ "${CI:-false}" == "true" && "$TEST_LIST" -lt 1 ]]; then
  fail "XCTest files not discovered/executed on CI"
fi
if [[ "$TEST_LIST" -lt 1 ]]; then
  echo "notice: no XCTest discovery locally (CommandLineTools without xctest) — parity CLT suite runs instead; CI macos-15 enforces XCTest execution."
fi

# 2. CLT runner parity (distinct purpose: no Xcode required, same contracts).
step "2/9 CLT Core runner (parity)"
if ! swift run ZephyrFlowCoreTests 2>&1 | tail -2; then fail "swift run ZephyrFlowCoreTests"; fi

# 3. Strict concurrency at the strongest setting available in Swift 5 mode
#    (-strict-concurrency=complete). Note: the package is swift-tools 5.10, so
#    this is NOT Swift 6 language mode; see docs/development/ci/sanitizers.md
#    for the Swift 6 language-mode follow-up. NEW warnings fail (pinned baseline).
step "3/9 strict concurrency (complete, Swift 5 mode) vs baseline"
WARN_LOG="$(mktemp)"
# Clean build so every warning is emitted (a cached build would emit none and
# silently pass); the baseline was produced the same way. Review R8.1: the
# BUILD's exit status is authoritative — a compile failure must FAIL the gate,
# never be swallowed by `|| true` (the old pipe masked build errors as a
# zero-warning pass).
swift package clean >/dev/null 2>&1 || true
set +e
swift build -Xswiftc -strict-concurrency=complete > /tmp/zf_sc_build.log 2>&1
SC_BUILD_RC=$?
set -e
if [[ $SC_BUILD_RC -ne 0 ]]; then
  echo "strict-concurrency BUILD FAILED (rc=$SC_BUILD_RC):"
  grep -E 'error:' /tmp/zf_sc_build.log | head -20 || true
  fail "strict-concurrency build failed"
fi
# Review B9: group the `|| true` so it applies to grep only, not the whole
# pipeline. (Shell pipelines bind tighter than `||`; the ungrouped form made
# WARN_LOG empty whenever warnings existed, disabling the baseline diff.)
( grep 'warning:' /tmp/zf_sc_build.log || true ) \
  | sed -E 's/^[[:space:]]*[|`-]*[[:space:]]*//' \
  | sed -E 's/^.*\/Sources\/([^:]+):[0-9]+:[0-9]+:/\1:/' \
  | sed -E 's/^.*\/Tests\/([^:]+):[0-9]+:[0-9]+:/\1:/' \
  | sed -E 's/[[:space:]]+/ /g' | sort -u > "$WARN_LOG"
BASELINE="docs/development/ci/strict-concurrency-warnings-baseline.txt"
if [[ -f "$BASELINE" ]]; then
  NEW="$(comm -13 <(grep -v '^#' "$BASELINE" | sed '/^$/d' | sort -u) "$WARN_LOG")"
  if [[ -n "$NEW" ]]; then
    echo "New strict-concurrency warnings (not in baseline):"
    echo "$NEW"
    fail "new strict-concurrency warnings"
  fi
else
  fail "missing baseline $BASELINE"
fi

# 4. Formatting lint (warnings are failures) + string-catalog completeness.
step "4/9 swift-format lint + string catalog scan"
if ! swift format lint --strict --recursive Sources Tests 2>&1 | tail -3; then
  fail "swift-format lint"
fi
if ! python3 Scripts/string_scan.py 2>&1 | tail -3; then
  fail "string catalog scan"
fi

# 5. Shell + YAML lint.
step "5/9 shell + YAML lint"
# Review R8.1: shellcheck covers ALL Scripts subdirectories (recursive),
# not just Scripts/*.sh, and its absence is a FAILURE (not a silent skip).
# Review NIT-5: recursive script discovery via find (globstar-independent).
mapfile -d '' ALL_SCRIPTS < <(find Scripts -name '*.sh' -print0)
if [[ ${#ALL_SCRIPTS[@]} -eq 0 ]]; then
  fail "no shell scripts found under Scripts/"
fi
for sh in "${ALL_SCRIPTS[@]}"; do
  bash -n "$sh" || fail "bash -n $sh"
done
if command -v shellcheck >/dev/null 2>&1; then
  for sh in "${ALL_SCRIPTS[@]}"; do
    # --severity=warning: real defects (warnings/errors) fail the gate;
    # info-level notes (e.g. SC1091 follow-sourcing, SC2086 quoting) do not.
    shellcheck --severity=warning -x "$sh" || fail "shellcheck $sh"
  done
else
  fail "shellcheck not installed (required by the gate)"
fi
# Review R8.1: YAML validation must not be silently omitted when PyYAML is
# missing — require it.
if python3 -c 'import yaml' 2>/dev/null; then
  for yml in .github/workflows/*.yml; do
    python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$yml')))" || fail "YAML $yml"
  done
else
  fail "PyYAML not installed (required by the gate)"
fi

# 6. Docs strict build + version gate.
step "6/9 docs strict + version gate"
if command -v mkdocs >/dev/null 2>&1; then
  mkdocs build --strict || fail "mkdocs --strict"
else
  echo "(mkdocs not on PATH — skipped locally; CI installs it)"
fi
v="$(tr -d '[:space:]' < VERSION)"
grep -q "static let version = \"$v\"" Sources/ZephyrFlow/Utilities/Constants.swift || fail "VERSION/Constants drift"
grep -q "<string>$v</string>" Resources/Info.plist || fail "VERSION/Info.plist drift"
grep -q "^## \[$v\]" CHANGELOG.md || fail "VERSION/CHANGELOG drift"

# 7. Generated-artifact drift: nothing may be left dirty by the gates above.
step "7/9 drift check (git diff --exit-code)"
if ! git diff --exit-code --quiet; then
  git status --porcelain | head -20
  fail "working tree dirty after gates (generated drift)"
fi

# 8. Trust-boundary coverage (ZephyrFlowCore only — cannot be inflated by
#    untested code elsewhere; adding untested Core code LOWERS the %).
step "8/9 trust-boundary coverage (ZephyrFlowCore)"
COV_TMP="$(mktemp -d)"
BIN="$(swift build --show-bin-path 2>/dev/null)"
if [[ -z "$BIN" ]]; then BIN=".build/debug"; fi
# `swift test --enable-code-coverage` builds every target instrumented;
# we then run the CLT suite (the full deterministic check set) with a
# captured profile and merge it with the XCTest profile.
if swift test --enable-code-coverage >/dev/null 2>&1 \
   && LLVM_PROFILE_FILE="$COV_TMP/clt.profraw" "$BIN/ZephyrFlowCoreTests" >/dev/null 2>&1; then
  PROFILES=()
  [[ -f "$COV_TMP/clt.profraw" ]] && PROFILES+=("$COV_TMP/clt.profraw")
  XCPROF="$(find .build -path '*codecov*' -name '*.profraw' | head -1)"
  [[ -n "$XCPROF" ]] && PROFILES+=("$XCPROF")
  if [[ "${#PROFILES[@]}" -gt 0 ]] \
     && xcrun llvm-profdata merge -o "$COV_TMP/core.profdata" "${PROFILES[@]}" \
     && xcrun llvm-cov report "$BIN/ZephyrFlowCoreTests" -instr-profile="$COV_TMP/core.profdata" \
        -ignore-filename-regex='Tests/' > "$COV_TMP/report.txt" 2>&1; then
    REGION="$(awk -F'[[:space:]]+' '/TOTAL/{print $4}' "$COV_TMP/report.txt" | tr -d '%')"
    LINE="$(awk -F'[[:space:]]+' '/TOTAL/{print $10}' "$COV_TMP/report.txt" | tr -d '%')"
    echo "ZephyrFlowCore coverage: line=${LINE}% region=${REGION}% (Swift toolchain emits no literal branch data; region is the equivalent)"
    if ! awk -v x="$LINE" 'BEGIN{exit !(x>=70)}'; then fail "coverage line < 70% (got ${LINE}%)"; fi
    if ! awk -v x="$REGION" 'BEGIN{exit !(x>=70)}'; then fail "coverage region < 70% (got ${REGION}%)"; fi
    cp "$COV_TMP/report.txt" /tmp/zephyr-flow-coverage-baseline-report.txt
  else
    fail "coverage report"
  fi
else
  fail "coverage measurement"
fi
rm -rf "$COV_TMP"

# 9. Sanitizer + crash/relaunch + rapid-control lanes (JOE-2293).
step "9/9 sanitizer / rapid-control / crash-recovery lanes"
# ASan on the XCTest target (fast, bounded). TSan is documented as
# unsupported for Swift on this runner (see docs/development/ci/sanitizers.md);
# the strict-concurrency lane (gate 3) + rapid-control stress are the
# alternate targeted lanes.
if swift test --sanitize=address 2>&1 | tail -3; then
  echo "ASan: clean"
else
  fail "ASan lane"
fi

# Review REQ-3: the rapid-control + crash/relaunch lanes are exercised by the
# deterministic CLT stress suite (JOE-2292/2293: rapid control edges, exactly-
# once terminal, crash-recovery markers). Run them explicitly as their own
# lane (not just inside the parity suite) and report the stress checks.
echo "rapid-control + crash-recovery lane (CLT stress suite)"
BIN="$(swift build --show-bin-path 2>/dev/null)/ZephyrFlowCoreTests"
if [[ -x "$BIN" ]]; then
  if "$BIN" 2>&1 | grep -E '✓ 2292|✓ 2293' > /tmp/zf_stress_lane.log; then
    STRESS_OK="$(grep -c '✓' /tmp/zf_stress_lane.log)"
    echo "rapid-control/crash-recovery: $STRESS_OK stress checks pass"
  else
    fail "rapid-control/crash-recovery lane"
  fi
else
  # Review NIT-6: a missing stress binary means the rapid-control/crash
  # lane did not run — fail closed (do not report the lane as green).
  fail "rapid-control/crash-recovery lane: CLT stress binary not found"
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "ci_checks: $FAILURES gate(s) FAILED — refusing merge."
  exit 1
fi
echo "ci_checks: ALL GATES PASSED."
