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

# 1. XCTest target is authoritative.
step "1/8 XCTest (swift test)"
if ! swift test 2>&1 | tail -3; then fail "swift test"; fi

# 2. CLT runner parity (distinct purpose: no Xcode required, same contracts).
step "2/8 CLT Core runner (parity)"
if ! swift run ZephyrFlowCoreTests 2>&1 | tail -2; then fail "swift run ZephyrFlowCoreTests"; fi

# 3. Swift 6 strict concurrency at the strongest supported setting; NEW
#    warnings fail (pinned baseline).
step "3/8 strict concurrency (complete) vs baseline"
WARN_LOG="$(mktemp)"
# Clean build so every warning is emitted (a cached build would emit none and
# silently pass); the baseline was produced the same way.
swift package clean >/dev/null 2>&1 || true
swift build -Xswiftc -strict-concurrency=complete 2>&1 \
  | grep 'warning:' | sed -E 's/^[[:space:]]*[|`-]*[[:space:]]*//' \
  | sed -E 's/[[:space:]]+/ /g' | sort -u > "$WARN_LOG" || true
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

# 4. Formatting lint (warnings are failures).
step "4/8 swift-format lint --strict"
if ! swift format lint --strict --recursive Sources Tests 2>&1 | tail -3; then
  fail "swift-format lint"
fi

# 5. Shell + YAML lint.
step "5/8 shell + YAML lint"
for sh in Scripts/*.sh; do
  bash -n "$sh" || fail "bash -n $sh"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck Scripts/*.sh || fail "shellcheck"
fi
if command -v python3 >/dev/null 2>&1; then
  for yml in .github/workflows/*.yml; do
    python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$yml')))" || fail "YAML $yml"
  done
fi

# 6. Docs strict build + version gate.
step "6/8 docs strict + version gate"
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
step "7/8 drift check (git diff --exit-code)"
if ! git diff --exit-code --quiet; then
  git status --porcelain | head -20
  fail "working tree dirty after gates (generated drift)"
fi

# 8. Trust-boundary coverage (ZephyrFlowCore only — cannot be inflated by
#    untested code elsewhere; adding untested Core code LOWERS the %).
step "8/8 trust-boundary coverage (ZephyrFlowCore)"
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
    cp "$COV_TMP/report.txt" docs/development/ci/coverage-baseline-report.txt
  else
    fail "coverage report"
  fi
else
  fail "coverage measurement"
fi
rm -rf "$COV_TMP"

echo
if [[ "$FAILURES" -gt 0 ]]; then
  echo "ci_checks: $FAILURES gate(s) FAILED — refusing merge."
  exit 1
fi
echo "ci_checks: ALL GATES PASSED."
