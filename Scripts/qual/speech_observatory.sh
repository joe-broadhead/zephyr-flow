#!/usr/bin/env bash
# JOE-2294/2295/2296 real-speech observatory + hardware profile (manual).
set -euo pipefail
QUAL_NAME="speech-observatory" source "$(dirname "$0")/_common.sh"
echo "## Real-speech observatory (manual, hardware required)" >> "$REPORT"
cat >> "$REPORT" <<'EOF'
- Corpus: 50 fixed utterances, one per session; capture WER/CER per utterance
  from the app's SessionTelemetry (JOE-2264) — metrics only, no transcripts.
- Silence false positives: 20 silent sessions, expect zero partials.
- Named hardware: record model, macOS, toolchain; 15-min profile: hold-to-
  first-partial latency, RSS peak, energy impact, thermal, battery drain.
- Soak: 1,000 sessions; confirm no leak growth and JOE-2292 invariants.
- Results go to this report; metrics are committed, transcript bodies never.
EOF
qual_ok "observatory runbook recorded"
echo "failures: $FAILURES"
exit "$FAILURES"
