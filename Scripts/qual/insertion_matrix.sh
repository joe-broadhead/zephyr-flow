#!/usr/bin/env bash
# JOE-2273/2274 supported-app insertion matrix + focus/secure-field probes.
set -euo pipefail
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_NAME="insertion-matrix" source "$(dirname "$0")/_common.sh"
(( $# == 0 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "## Insertion + target-validation checks (deterministic, CLT)" >> "$REPORT"
echo >> "$REPORT"
qual_core_checks 2268 2269 2270 2260
cat >> "$REPORT" <<'EOF'

## Real-app matrix (manual, hardware required)
- Apps: Notes, TextEdit, Terminal, Safari, VS Code, Slack (25 rounds each).
- Record exact candidate artifact hash, OS/app versions and result per case.
- For each: dictate into a caret, expect exact insertion; switch target
  mid-session and confirm rollback/no stale-bundle fallback (JOE-2268).
- Secure fields (1Password/Keychain style): confirm fail-closed, no insert.
- Hung AX target: confirm bounded TargetRestoreMonitor recovery, app usable.
- Pasteboard path: confirm exact restore on failure (JOE-2260).
EOF
qual_not_run 'six-app insertion matrix has no executed cases or measured outcomes'
echo "failures: $FAILURES"
qual_finish
