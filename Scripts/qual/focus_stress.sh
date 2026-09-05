#!/usr/bin/env bash
# Review R8.2: focus-switch / secure-field / hung-AX / clipboard-race
# qualification (JOE-2274). Matches human-gates.md runbook.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_USAGE="$0 [round-count]" QUAL_NAME="focus_stress" source "$HERE/_common.sh"
ROUNDS="${1:-40}"
qual_integer "$ROUNDS"
(( $# <= 1 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "Requested rounds: $ROUNDS (not driven)" >> "$REPORT"
qual_not_run 'no verified focus/insertion session driver; no target IPC deadline or clipboard-race measurements'
echo "Manual expectations (record in report):"
echo "  - no insertion into secure fields (fail-closed JOE-2259/2268)"
echo "  - hung AX targets bounded (TargetRestoreMonitor)"
echo "  - pasteboard restored exactly on failure (JOE-2260)"
qual_finish
