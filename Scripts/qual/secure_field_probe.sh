#!/usr/bin/env bash
# Review R8.2: secure-field probe (JOE-2259/2274). Run while a secure field
# (1Password/Keychain-style) is focused.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh source-path=SCRIPTDIR
QUAL_NAME="secure_field_probe" source "$HERE/_common.sh"
(( $# == 0 )) || { qual_fail 'unexpected arguments'; qual_finish; }
echo "-> Focus a SECURE field (password) in any app, then run a dictation."
echo "   Expect: no auto paste, no auto copy, no history (fail-closed)."
echo "   Then use the review panel's explicit Copy to verify it works."
qual_not_run 'secure/unknown-field confinement and explicit-copy behavior not exercised'
echo "Manual expectations:"
echo "  - secure/unknown targets never write clipboard automatically (R9)"
echo "  - review panel explicit copy is the only .explicitlyCopiedByUser path"
qual_finish
