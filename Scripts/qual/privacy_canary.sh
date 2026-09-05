#!/usr/bin/env bash
# JOE-2297 end-to-end privacy canary matrix (deterministic portion).
set -euo pipefail
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_NAME="privacy-canary" source "$(dirname "$0")/_common.sh"
(( $# == 0 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "## Privacy canary (deterministic, CLT)" >> "$REPORT"
echo >> "$REPORT"
qual_core_checks 2261 2262 2259 2264
cat >> "$REPORT" <<'EOF'

## Real-app canary (manual, hardware required)
- Build + run the app with Local Only ON; confirm no network connections
  (Little Snitch / lsof -i for the app pid).
- Dictate a fixed phrase; confirm no transcript body appears in Console/logs
  (ZFLog logs lengths only).
- With saveHistory OFF confirm no new history writes; with ON confirm allowed
  history payloads remain encrypted on disk even while the UI is unlocked.
- Record artifact identity, network classes observed (model acquisition vs
  audio), canary surfaces, sampling interval and limitations. A point-in-time
  connection listing is not proof that no network traffic occurred.
EOF
qual_not_run 'end-to-end device privacy canary and network observations absent'
echo "failures: $FAILURES"
qual_finish
