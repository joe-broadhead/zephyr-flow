#!/usr/bin/env bash
# 1,000-session soak planning (JOE-2296). No app-driving hook is implemented.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_USAGE="$0 [session-count] [app-path]" QUAL_NAME="soak_1000" source "$HERE/_common.sh"
SESSIONS="${1:-1000}"
APP="${2:-Dist/ZephyrFlow.app}"
qual_integer "$SESSIONS"
(( $# <= 2 )) || { qual_fail 'unexpected arguments'; qual_finish; }
printf 'Requested sessions: %s\nRequested app (not verified or launched): %s\n' "$SESSIONS" "$APP" >> "$REPORT"
qual_not_run 'no session driver, terminal-event collector, exact-app identity or leak measurements'
echo 'Required: drive real sessions; reconcile press/capture/terminal/release counts and resource growth without transcript bodies.' >> "$REPORT"
qual_finish
