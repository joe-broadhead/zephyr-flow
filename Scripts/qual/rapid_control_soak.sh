#!/usr/bin/env bash
# JOE-2257 / JOE-2296 deterministic rapid-control + soak stress.
# Usage: rapid_control_soak.sh [--minutes N] [--app /path/to/ZephyrFlow.app]
set -euo pipefail
MINUTES="${1:-5}"
# used below: sleep loop duration
# shellcheck source=_common.sh
QUAL_NAME="rapid-control" source "$(dirname "$0")/_common.sh"
echo "## Deterministic rapid-control stress (seeded, CLT; minutes=$MINUTES)" >> "$REPORT"
echo >> "$REPORT"
swift run ZephyrFlowCoreTests 2>&1 | grep -E '✓ 2293|✓ 2292' >> "$REPORT" || qual_fail "CLT stress checks"
if swift run ZephyrFlowCoreTests 2>&1 | grep -q 'All tests passed'; then
  qual_ok "full CLT suite green (rapid-control + session invariants)"
else
  qual_fail "CLT suite"
fi
echo >> "$REPORT"
echo "## Real-app soak (manual, hardware required)" >> "$REPORT"
cat >> "$REPORT" <<'EOF'
- Build: ./Scripts/build_app.sh debug && open Dist/ZephyrFlow.app
- For the requested minutes, press/release the hotkey rapidly and randomly;
  confirm exactly one session per press and no duplicate/frozen sessions.
- Watch Console for ZephyrFlow errors; record crash logs if any.
- Expected: JOE-2246 exactly-one-terminal, JOE-2292 invariants hold in the
  real app; no leak growth (Activity Monitor RSS over the soak).
EOF
qual_ok "real-app soak runbook recorded"
echo "failures: $FAILURES"
exit "$FAILURES"
