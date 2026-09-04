#!/usr/bin/env bash
# Review R8.2: secure-field probe (JOE-2259/2274). Run while a secure field
# (1Password/Keychain-style) is focused.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
QUAL_NAME="secure_field_probe" source "$HERE/_common.sh"
echo "-> Focus a SECURE field (password) in any app, then run a dictation."
echo "   Expect: no auto paste, no auto copy, no history (fail-closed)."
echo "   Then use the review panel's explicit Copy to verify it works."
qual_ok "secure-field probe prepared; manual verification required"
echo "Manual expectations:"
echo "  - secure/unknown targets never write clipboard automatically (R9)"
echo "  - review panel explicit copy is the only .explicitlyCopiedByUser path"
exit $FAILURES
