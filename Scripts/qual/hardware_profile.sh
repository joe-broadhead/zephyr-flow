#!/usr/bin/env bash
# Review R8.2: named-hardware latency/memory/energy/thermal/battery profile
# (JOE-2295). Runbook only; no verified process or instrumentation driver.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_USAGE="$0 [minutes] [app-path]" QUAL_NAME="hardware_profile" source "$HERE/_common.sh"
MINUTES="${1:-15}"
APP="${2:-Dist/ZephyrFlow.app}"
qual_integer "$MINUTES"
(( $# <= 2 )) || { qual_fail 'unexpected arguments'; qual_finish; }
printf 'Requested minutes: %s\nRequested app (not verified or launched): %s\n' "$MINUTES" "$APP" >> "$REPORT"
qual_not_run 'latency, RSS, energy, thermal and battery measurements absent; process identity not verified'
echo "Manual: record hold-to-first-partial latency, RSS peak, energy impact,"
echo "thermal state, battery drain per named machine (JOE-2295)."
qual_finish
