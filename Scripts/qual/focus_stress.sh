#!/usr/bin/env bash
# Review R8.2: focus-switch / secure-field / hung-AX / clipboard-race
# qualification (JOE-2274). Matches human-gates.md runbook.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
QUAL_NAME="focus_stress" source "$HERE/_common.sh"
ROUNDS="${1:-40}"
echo "-> focus stress rounds=$ROUNDS"
seq 1 "$ROUNDS" | while read -r _; do
  osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Notes" to true' 2>/dev/null || true
  sleep 0.1
  osascript -e 'tell application "System Events" to set frontmost of first process whose name is "TextEdit" to true' 2>/dev/null || true
  sleep 0.1
done
qual_ok "focus stress executed $ROUNDS rounds (manual AX verification required)"
echo "Manual expectations (record in report):"
echo "  - no insertion into secure fields (fail-closed JOE-2259/2268)"
echo "  - hung AX targets bounded (TargetRestoreMonitor)"
echo "  - pasteboard restored exactly on failure (JOE-2260)"
exit $FAILURES
