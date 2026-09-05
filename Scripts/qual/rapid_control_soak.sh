#!/usr/bin/env bash
# JOE-2257 / JOE-2296 deterministic rapid-control + soak stress.
# Usage: rapid_control_soak.sh [minutes]
set -euo pipefail
MINUTES="${1:-5}"
# used below: sleep loop duration
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_USAGE="$0 [minutes]" QUAL_NAME="rapid-control" source "$(dirname "$0")/_common.sh"
qual_integer "$MINUTES"
(( $# <= 1 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "## Deterministic rapid-control stress (seeded, CLT; minutes=$MINUTES)" >> "$REPORT"
echo >> "$REPORT"
qual_core_checks 2293 2292
cat >> "$REPORT" <<'EOF'

## Real-app soak (manual, hardware required)
- Build: ./Scripts/build_app.sh debug && open Dist/ZephyrFlow.app
- For the requested minutes, press/release the hotkey rapidly and randomly;
  confirm exactly one session per press and no duplicate/frozen sessions.
- Watch Console for ZephyrFlow errors; record crash logs if any.
- Expected: JOE-2246 exactly-one-terminal, JOE-2292 invariants hold in the
  real app; no leak growth (Activity Monitor RSS over the soak).
EOF
qual_not_run 'real-app rapid-control sessions and resource counters not collected'
echo "failures: $FAILURES"
qual_finish
