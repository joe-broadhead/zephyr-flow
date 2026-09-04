#!/usr/bin/env bash
# JOE-2299 prepared notarization flow (DRY-RUN ONLY until credentials exist).
# Requires: Apple Developer ID Application certificate in the keychain.
# Usage: notarize.sh --dry-run | --run
set -euo pipefail
MODE="${1:---dry-run}"
APP="Dist/ZephyrFlow.app"
TEAM_ID="${ZEPHYR_TEAM_ID:-}"           # set by the human
BUNDLE_ID="${ZEPHYR_BUNDLE_ID:-com.zephyrflow.app}"
if [[ "$MODE" == "--dry-run" ]]; then
  echo "DRY RUN: would (1) codesign --options runtime, (2) notarytool submit,"
  echo "         (3) staple, (4) verify Gatekeeper clean-install."
  echo "Preconditions: ZEPHYR_TEAM_ID + Developer ID certificate + notarytool"
  echo "credentials (App Store Connect API key or Apple ID)."
  echo "Exact commands:"
  echo "  codesign --deep --strict --options runtime --sign 'Developer ID Application' \\"
  echo "    --identifier $BUNDLE_ID $APP"
  echo "  ditto -c -k --keepParent $APP $APP.zip"
  echo "  xcrun notarytool submit $APP.zip --team-id \$ZEPHYR_TEAM_ID --wait"
  echo "  xcrun stapler staple $APP"
  echo "  codesign --verify --deep --strict --verbose=2 $APP && spctl -a -vv $APP"
  exit 0
fi
if [[ -z "$TEAM_ID" ]]; then echo "set ZEPHYR_TEAM_ID first"; exit 1; fi
echo "REAL NOTARIZATION NOT CONFIGURED — run only after JOE-2298 + human credential supply."
exit 1
