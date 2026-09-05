#!/usr/bin/env bash
# JOE-2294/2295/2296 real-speech observatory + hardware profile (manual).
set -euo pipefail
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_NAME="speech-observatory" source "$(dirname "$0")/_common.sh"
(( $# == 0 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "## Real-speech observatory (manual, hardware required)" >> "$REPORT"
cat >> "$REPORT" <<'EOF'
- Corpus: 50 fixed utterances, one per session; compare permitted reference
  and hypothesis text in a controlled evaluator to compute WER/CER. The app's
  content-free telemetry does not provide a WER/CER evaluator.
- Silence false positives: 20 silent sessions, expect zero partials.
- Named hardware: record model, macOS, toolchain; 15-min profile: hold-to-
  first-partial latency, RSS peak, energy impact, thermal, battery drain.
- Soak: 1,000 sessions; confirm no leak growth and JOE-2292 invariants.
- Keep results/evidence outside the repository. Do not commit personal logs,
  transcript bodies or audit dumps. Record exact candidate artifact identity.
EOF
qual_not_run 'no recorded utterances, evaluator output or hardware/soak measurements'
echo "failures: $FAILURES"
qual_finish
