#!/usr/bin/env bash
# Always fail closed until a separately reviewed verifier binds an exact source,
# artifact, qualification reports, independent review and explicit human GO.
# A CLI flag, CI green, tag, credential or arbitrary JSON file is not approval.
set -euo pipefail
if [[ $# -eq 1 && "$1" == --help ]]; then
  printf '%s\n' 'Production acceptance verifier is not configured. No override flags exist.'
  exit 0
fi
printf '%s\n' 'RELEASE BLOCKED: exact-candidate production acceptance verifier is not configured.' >&2
printf '%s\n' 'No tag, credential access, signing, upload, workflow dispatch or publication is authorized by this preflight.' >&2
exit 1
