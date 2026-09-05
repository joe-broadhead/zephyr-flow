#!/usr/bin/env bash
# Shared runbook bootstrap. A prepared checklist is not qualification evidence.
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then echo 'Source _common.sh from a qualification helper.' >&2; exit 1; fi
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: %s\n' "${QUAL_USAGE:-$0}"
  echo 'Prepares an INCOMPLETE report, not device qualification. Exit 2 = NOT RUN; exit 1 = check/tool failure.'
  exit 0
fi
QUAL_REPORT_DIR="${QUAL_REPORT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/zephyr-qual.XXXXXX")}"
mkdir -p "$QUAL_REPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp "$QUAL_REPORT_DIR/$STAMP-${QUAL_NAME:-qual}.XXXXXX")"
FAILURES=0
INCOMPLETE=0
qual_ok() { echo "- [CHECK PASSED] $*" >> "$REPORT"; }
qual_fail() { echo "- [FAIL] $*" >> "$REPORT"; FAILURES=$((FAILURES+1)); }
qual_not_run() { echo "- [NOT RUN] $*" >> "$REPORT"; INCOMPLETE=$((INCOMPLETE+1)); }
qual_finish() {
  if (( FAILURES > 0 )); then echo 'RESULT: FAIL' >> "$REPORT"; exit 1; fi
  if (( INCOMPLETE > 0 )); then echo 'RESULT: INCOMPLETE' >> "$REPORT"; exit 2; fi
  # No current helper has an exact-candidate qualification driver. A new
  # implementation must supply reviewed evidence validation, not set a flag.
  echo 'RESULT: INCOMPLETE (no exact-candidate qualification verifier)' >> "$REPORT"
  exit 2
}
qual_integer() {
  if [[ ! "$1" =~ ^[1-9][0-9]{0,5}$ ]]; then
    qual_fail "invalid positive count: expected 1..999999"
    qual_finish
  fi
}
qual_core_checks() {
  local log="$REPORT.core.log" probe
  if swift run ZephyrFlowCoreTests > "$log" 2>&1; then
    qual_ok 'Core command exit 0 (synthetic contract tests, not app qualification)'
  else
    local rc=$?
    qual_fail "Core command exit $rc; retain $log"
    return
  fi
  if ! grep -q 'All tests passed' "$log"; then qual_fail 'Core completion marker missing'; fi
  for probe in "$@"; do
    if grep -q "✓ $probe" "$log"; then qual_ok "Core contract assertions $probe"; else qual_fail "Core assertion group $probe missing"; fi
  done
}
{
  echo "# $STAMP ${QUAL_NAME:-qual}"
  echo
  echo 'Qualification status: INCOMPLETE until exact-candidate measurements are independently reviewed.'
  echo '- Candidate artifact identity: NOT RECORDED (repo metadata alone does not identify a running app)'
  echo '- Executed device sessions: NOT RECORDED'
  echo "- date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} > "$REPORT"
echo "report: $REPORT"
for tool in 'sw_vers -productVersion' 'sysctl -n hw.model' 'swift --version' 'git rev-parse HEAD' 'git rev-parse HEAD^{tree}'; do
  # Fixed reviewed commands only, never eval or caller-controlled input.
  read -r -a command_args <<< "$tool"
  if metadata="$("${command_args[@]}" 2>&1)"; then
    printf -- '- %s: %s\n' "$tool" "$metadata" >> "$REPORT"
  else
    qual_fail "metadata command failed: $tool"
  fi
done
if git diff --quiet && git diff --cached --quiet; then
  echo '- Tracked source: clean' >> "$REPORT"
else
  qual_not_run 'source has tracked changes or cannot be inspected; HEAD is not exact working-source identity'
fi
