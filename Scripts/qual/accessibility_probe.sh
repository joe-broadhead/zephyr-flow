#!/usr/bin/env bash
# Accessibility runbook (JOE-2288). Does not change system features or measure UI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_NAME="accessibility_probe" source "$HERE/_common.sh"
(( $# == 0 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "-> Enable VoiceOver, Full Keyboard Access, Reduce Motion, Increase"
echo "   Contrast (System Settings > Accessibility). Exercise Settings,"
echo "   Onboarding and the floating panel. Record per-feature pass/fail."
qual_not_run 'VoiceOver, keyboard navigation, motion, contrast and panel focus measurements absent'
echo "Checklist: VoiceOver labels, keyboard navigation, reduced-motion,"
echo "contrast, panel focus. Record results per feature in the report."
qual_finish
