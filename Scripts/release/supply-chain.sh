#!/usr/bin/env bash
# Historical plan-only success was not supply-chain evidence.
set -euo pipefail
if [[ $# -eq 1 && "$1" == --help ]]; then
  printf '%s\n' 'Usage: supply-chain.sh --dry-run | --help'
  exit 0
fi
if [[ $# -eq 0 || ( $# -eq 1 && "$1" == --dry-run ) ]]; then
  printf '%s\n' 'NOT RUN: reviewed SBOM generation, signed provenance and signed update manifest are not configured.'
  printf '%s\n' 'Package.resolved/dump-package are dependency metadata, not a complete SBOM or provenance attestation.'
  exit 2
fi
printf '%s\n' 'SUPPLY-CHAIN BLOCKED: no production verifier/signing policy; refusing execution.' >&2
exit 1
