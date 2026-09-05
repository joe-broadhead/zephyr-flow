#!/bin/bash
# Bounded local-tokenizer XCTest lane. The kernel denies IP networking for
# this process and its children; no external endpoint is contacted by the
# policy check. This is not general app privacy/device qualification.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
command -v sandbox-exec >/dev/null
BIN="$(swift build --show-bin-path)"
XCTEST="$(xcrun --find xctest)"
BUNDLE="$BIN/ZephyrFlowPackageTests.xctest"
if [[ ! -d "$BUNDLE" ]]; then
  echo "Missing prebuilt XCTest bundle: $BUNDLE" >&2
  exit 1
fi
POLICY='(version 1) (allow default) (deny network*)'

# A UDP connect to loopback sends no payload and needs no listening service.
# Prove permission denial, not merely DNS/server unavailability. If sandbox
# support disappears or its policy becomes ineffective, this lane must fail.
sandbox-exec -p "$POLICY" python3 -c '
import errno, socket
try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(("127.0.0.1", 9))
except OSError as error:
    if error.errno not in (errno.EPERM, errno.EACCES):
        raise
    print("Sandbox network denial verified")
else:
    raise SystemExit("Sandbox did not deny networking")
'
# Invoke the already-built bundle, not SwiftPM: nested manifest sandboxes
# cannot be installed after sandbox_apply. Do not disable either sandbox or
# retry this test without network denial if execution fails.
sandbox-exec -p "$POLICY" "$XCTEST" -XCTest ZephyrFlowTests.ProductionOfflineTokenizerTests "$BUNDLE"
