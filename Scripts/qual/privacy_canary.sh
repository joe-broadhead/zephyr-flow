#!/usr/bin/env bash
# JOE-2297 end-to-end privacy canary matrix (deterministic portion).
set -euo pipefail
# shellcheck source=_common.sh
QUAL_NAME="privacy-canary" source "$(dirname "$0")/_common.sh"
echo "## Privacy canary (deterministic, CLT)" >> "$REPORT"
echo >> "$REPORT"
OUT="$(swift run ZephyrFlowCoreTests 2>&1 || true)"
for probe in '2261' '2262' '2259' '2264'; do
  if echo "$OUT" | grep -q "✓ $probe"; then qual_ok "privacy probe $probe"; else qual_fail "privacy probe $probe"; fi
done
if echo "$OUT" | grep -q 'All tests passed'; then qual_ok "all privacy/sensitivity checks green"; fi
echo >> "$REPORT"
echo "## Real-app canary (manual, hardware required)" >> "$REPORT"
cat >> "$REPORT" <<'EOF'
- Build + run the app with Local Only ON; confirm no network connections
  (Little Snitch / lsof -i for the app pid).
- Dictate a fixed phrase; confirm no transcript body appears in Console/logs
  (ZFLog logs lengths only).
- With saveHistory OFF confirm no plaintext history; with ON confirm the
  history file is encrypted at rest (JOE-2262) unless the store is unlocked.
EOF
qual_ok "real-app canary runbook recorded"
echo "failures: $FAILURES"
exit "$FAILURES"
