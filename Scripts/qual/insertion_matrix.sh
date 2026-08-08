#!/usr/bin/env bash
# JOE-2273/2274 supported-app insertion matrix + focus/secure-field probes.
set -euo pipefail
QUAL_NAME="insertion-matrix" source "$(dirname "$0")/_common.sh"
echo "## Insertion + target-validation checks (deterministic, CLT)" >> "$REPORT"
echo >> "$REPORT"
OUT="$(swift run ZephyrFlowCoreTests 2>&1 || true)"
for probe in '2268' '2269' '2270' '2260'; do
  if echo "$OUT" | grep -q "✓ $probe"; then qual_ok "target/insertion probe $probe"; else qual_fail "target/insertion probe $probe"; fi
done
echo >> "$REPORT"
echo "## Real-app matrix (manual, hardware required)" >> "$REPORT"
cat >> "$REPORT" <<'EOF'
- Apps: Notes, TextEdit, Mail, Safari, Slack, Terminal (25 rounds each).
- For each: dictate into a caret, expect exact insertion; switch target
  mid-session and confirm rollback/no stale-bundle fallback (JOE-2268).
- Secure fields (1Password/Keychain style): confirm fail-closed, no insert.
- Hung AX target: confirm bounded TargetRestoreMonitor recovery, app usable.
- Pasteboard path: confirm exact restore on failure (JOE-2260).
EOF
qual_ok "real-app matrix runbook recorded"
echo "failures: $FAILURES"
exit "$FAILURES"
