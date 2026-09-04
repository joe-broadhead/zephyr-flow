#!/usr/bin/env bash
# Review R8.2: accessibility qualification (JOE-2288). Enables the features
# and guides the manual checklist; leaves state to the operator.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
QUAL_NAME="accessibility_probe" source "$HERE/_common.sh"
echo "-> Enable VoiceOver, Full Keyboard Access, Reduce Motion, Increase"
echo "   Contrast (System Settings > Accessibility). Exercise Settings,"
echo "   Onboarding and the floating panel. Record per-feature pass/fail."
qual_ok "accessibility probe prepared; manual checklist required"
echo "Checklist: VoiceOver labels, keyboard navigation, reduced-motion,"
echo "contrast, panel focus. Record results per feature in the report."
exit $FAILURES
