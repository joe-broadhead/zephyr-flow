#!/usr/bin/env bash
# Review R8.2: named-hardware latency/memory/energy/thermal/battery profile
# (JOE-2295). Records a 15-minute profile of the running app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
QUAL_NAME="hardware_profile" source "$HERE/_common.sh"
MINUTES="${1:-15}"
APP="${2:-Dist/ZephyrFlow.app}"
echo "-> Launch $APP and profile for $MINUTES minutes (hold-to-talk + latency)."
START="$(date +%s)"
END=$((START + MINUTES * 60))
while [ "$(date +%s)" -lt "$END" ]; do
  RSS="$(ps -axo rss,comm | awk -v app="$APP" '$2 ~ app {print $1/1024}' | head -1)"
  [ -n "${RSS:-}" ] && echo "RSS_MB=$RSS"
  sleep 5
done | awk '{print} END {print "profile complete"}' >> "$REPORT"
qual_ok "hardware profile executed ($MINUTES min; manual review of latency/energy)"
echo "Manual: record hold-to-first-partial latency, RSS peak, energy impact,"
echo "thermal state, battery drain per named machine (JOE-2295)."
exit $FAILURES
